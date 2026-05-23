# LocalVaultClient — In-Process Data Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the HTTP-sidecar round-trips for file reads/writes and metadata/search with a pure-Swift `LocalVaultClient` that touches the filesystem and the SQLite index directly, in-process.

**Architecture:** A `VaultClient` protocol already exists (`Sources/MarpleKit/VaultClient.swift`) and `HTTPVaultClient` conforms to it. We add a second conformer, `LocalVaultClient`, that (a) reads/writes vault markdown files directly via `FileManager`, and (b) reads list metadata + runs keyword search directly from the existing `<workspaceRoot>/.marple/index.sqlite` via GRDB. The Rust sidecar is **demoted to a background indexer** for this phase: it still watches the vault and maintains the SQLite index, but the app no longer talks to it over HTTP on the read/write/search path. Task 1 enables WAL on the Rust side so the app's concurrent reads never collide with the sidecar's reconcile writes (this also fixes the current `database is locked` error). Phases 2 (port the indexer to Swift, remove the sidecar) and 3 (semantic search) are separate plans.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Testing (`import Testing`), GRDB.swift (new dependency), the existing rusqlite-built SQLite FTS5 index (read-only from Swift).

---

## Why this is bounded and shippable on its own

After this plan: the native app reads files, lists metadata, and searches entirely in-process. The only thing still crossing to Rust is **background index maintenance** (no HTTP on the hot path). If the sidecar is off, reads/writes still work; only search/metadata go stale until the next index build. That is a coherent, testable end state.

## Key facts discovered (do not re-derive)

- Index DB path: `<workspaceRoot>/.marple/index.sqlite` (Rust `ReaderPaths::from_roots`, `rust/reader-core/src/lib.rs:79`).
- `entries` table columns (subset we read): `path, type, book, title, author, year_json, rating_score, themes_json, topic, source, doi, annotates, has_pdf, mtime, preview, added` (`rust/reader-core/src/indexer.rs:1162`).
- FTS5 tables: `entry_search` (structured, default tokenizer) and `entry_trigram(path UNINDEXED, type UNINDEXED, text, tokenize='trigram')` (`indexer.rs:1206`, `:1221`). **Use `entry_trigram` for search** — it is the only one that segments Chinese (the vault is heavily CJK).
- Vault dir: `<workspaceRoot>/vault`. Trash dir: `<workspaceRoot>/vault/notes/.trash` (`lib.rs:81`). Trash filename format: `{base}.{ts}.md` (`lib.rs:1448`).
- `Entry` model + its JSON↔field mapping: `Sources/MarpleKit/Entry.swift` (`year` derives from `year_json`; `themes` from `themes_json`; `hasPDF` from `has_pdf` int; `mtime`/`added` are epoch-ms Doubles).
- Client construction (swap point): `Sources/Marple/MarpleApp.swift:16-21`.
- Tests run with `swift test` from `apple/`. Framework: Swift Testing (`@Suite`, `@Test`, `#expect`, `Issue.record`).

## File Structure

- Modify: `apple/Package.swift` — add GRDB dependency to the `MarpleKit` target.
- Create: `apple/Sources/MarpleKit/IndexDatabase.swift` — GRDB read layer over `index.sqlite` (`loadEntries`, `search`). One responsibility: read the index.
- Create: `apple/Sources/MarpleKit/LocalVaultClient.swift` — `VaultClient` conformer: file IO + delegate index/search to `IndexDatabase`.
- Create: `apple/Tests/MarpleKitTests/IndexDatabaseTests.swift` — fixture-DB tests for the read layer.
- Create: `apple/Tests/MarpleKitTests/LocalVaultClientTests.swift` — temp-vault tests for file IO + delegation.
- Modify: `apple/Sources/Marple/MarpleApp.swift:16-21` — construct `LocalVaultClient`.
- Modify: `rust/reader-core/src/indexer.rs` + `rust/reader-core/src/lib.rs` — enable WAL via a shared open helper (Task 1).

---

### Task 1: Enable WAL on the Rust index DB (fixes `database is locked`, makes concurrent reads safe)

**Files:**
- Modify: `rust/reader-core/src/indexer.rs` (writer opens: `:358`, `:422`, `:435`)
- Modify: `rust/reader-core/src/lib.rs` (reader opens: `:265`, `:300`, `:372`, `:427`)

**Why:** The live `index.sqlite` runs in default rollback-journal mode; a writer needs an EXCLUSIVE lock that any concurrent reader blocks, so the watcher reconcile times out → `database is locked`. WAL lets many readers + one writer run concurrently. This must land before the Swift app opens the same file concurrently.

- [ ] **Step 1: Write a failing test**

Add to `rust/reader-core/tests/reconcile.rs` (or create it if absent):

```rust
use reader_core::ReaderPaths;
use rusqlite::{Connection, OpenFlags};

#[test]
fn index_db_is_wal_after_build() {
    // Arrange a tiny workspace with one vault file.
    let tmp = tempfile::tempdir().unwrap();
    let ws = tmp.path();
    std::fs::create_dir_all(ws.join("vault/papers")).unwrap();
    std::fs::write(
        ws.join("vault/papers/a.md"),
        "---\ntype: paper-analysis\ntitle: A\n---\nbody",
    )
    .unwrap();
    let paths = ReaderPaths::from_roots(ws, ws).unwrap();

    // Act: build the index.
    reader_core::reconcile_index(&paths).unwrap();

    // Assert: the DB is in WAL mode.
    let conn = Connection::open_with_flags(&paths.index_db, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let mode: String = conn
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .unwrap();
    assert_eq!(mode.to_lowercase(), "wal");
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd rust && cargo test -p reader-core index_db_is_wal_after_build`
Expected: FAIL — `assertion failed: left == "delete", right == "wal"` (or similar). Ensure `tempfile` is a dev-dependency in `rust/reader-core/Cargo.toml`; if missing, add `tempfile = "3"` under `[dev-dependencies]`.

- [ ] **Step 3: Add a shared connection-open helper and route writers through it**

In `rust/reader-core/src/indexer.rs`, add near the top (after the `use` block):

```rust
/// Open the live index DB read-write with the pragmas every writer needs:
/// WAL (readers never block the single writer), a 5s busy timeout, and
/// NORMAL sync (safe + fast under WAL). Centralizes what used to be repeated
/// per call site.
pub(crate) fn open_index_rw(path: &std::path::Path) -> ReaderResult<Connection> {
    let conn = Connection::open(path)
        .with_context(|| format!("failed to open {}", path.display()))?;
    conn.busy_timeout(std::time::Duration::from_millis(5000))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    Ok(conn)
}
```

Replace each writer open. At `indexer.rs:358-360`, `:422-424`, `:435-437`, change the two-line
```rust
    let conn = Connection::open(&paths.index_db)
        .with_context(|| format!("failed to open {}", paths.index_db.display()))?;
    conn.busy_timeout(std::time::Duration::from_millis(5000))?;
```
to
```rust
    let conn = open_index_rw(&paths.index_db)?;
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `cd rust && cargo test -p reader-core index_db_is_wal_after_build`
Expected: PASS.

- [ ] **Step 5: Run the full reader-core suite to confirm no regressions**

Run: `cd rust && cargo test -p reader-core`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add rust/reader-core/src/indexer.rs rust/reader-core/Cargo.toml rust/reader-core/tests/reconcile.rs
git commit -m "fix(reader-core): enable WAL on the index DB to end reconcile lock contention"
```

---

### Task 2: Add the GRDB dependency

**Files:**
- Modify: `apple/Package.swift`

- [ ] **Step 1: Add the package dependency**

In `apple/Package.swift`, add to the `dependencies:` array:

```swift
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
```

And add the product to the `MarpleKit` target dependencies:

```swift
        .target(
            name: "MarpleKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
```

- [ ] **Step 2: Resolve and build to confirm GRDB links**

Run: `cd apple && swift build`
Expected: build succeeds; GRDB resolves and compiles. (First resolve downloads GRDB; allow a minute.)

- [ ] **Step 3: Commit**

```bash
git add apple/Package.swift apple/Package.resolved
git commit -m "build(native): add GRDB dependency to MarpleKit"
```

---

### Task 3: `IndexDatabase` — GRDB read layer over the SQLite index

**Files:**
- Create: `apple/Sources/MarpleKit/IndexDatabase.swift`
- Test: `apple/Tests/MarpleKitTests/IndexDatabaseTests.swift`

- [ ] **Step 1: Write the failing tests (with a fixture-DB helper that builds the real schema)**

Create `apple/Tests/MarpleKitTests/IndexDatabaseTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import MarpleKit

@Suite struct IndexDatabaseTests {
    /// Build a throwaway index.sqlite with the production schema (subset we read)
    /// and the two FTS tables, then insert the given rows. Returns the file path.
    private func makeFixtureDB(_ rows: [(path: String, type: String, title: String,
                                        themesJSON: String?, yearJSON: String?,
                                        hasPDF: Int, rating: Double, text: String)]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("index.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE entries (
                  path TEXT PRIMARY KEY, type TEXT NOT NULL, book TEXT, title TEXT,
                  title_en TEXT, title_cn TEXT, author TEXT, year_json TEXT, rating_json TEXT,
                  rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, source TEXT,
                  doi TEXT, publisher TEXT, isbn TEXT, translation_title_cn TEXT,
                  translation_douban_url TEXT, chapters_analyzed INTEGER, annotates TEXT,
                  created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0, mtime INTEGER,
                  preview TEXT NOT NULL DEFAULT '', body_len INTEGER NOT NULL DEFAULT 0,
                  added INTEGER NOT NULL DEFAULT 0
                );
                CREATE VIRTUAL TABLE entry_trigram USING fts5(
                  path UNINDEXED, type UNINDEXED, text, tokenize = 'trigram'
                );
                """)
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO entries (path, type, title, year_json, rating_score, themes_json, has_pdf, preview, mtime, added)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [r.path, r.type, r.title, r.yearJSON, r.rating, r.themesJSON, r.hasPDF, "prev", 1000, 2000])
                try db.execute(sql: "INSERT INTO entry_trigram (path, type, text) VALUES (?, ?, ?)",
                               arguments: [r.path, r.type, r.text])
            }
        }
        return path
    }

    @Test func loadEntriesMapsColumns() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/a.md", type: "paper-analysis", title: "Alpha",
             themesJSON: #"["x","y"]"#, yearJSON: #""2014""#, hasPDF: 1, rating: 4.0, text: "alpha body"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.path == "vault/papers/a.md")
        #expect(e.type == .paperAnalysis)
        #expect(e.title == "Alpha")
        #expect(e.themes == ["x", "y"])
        #expect(e.year == "2014")
        #expect(e.hasPDF == true)
        #expect(e.ratingScore == 4.0)
    }

    @Test func loadEntriesReturnsEmptyWhenDBMissing() throws {
        let db = IndexDatabase(indexDBPath: "/nonexistent/index.sqlite")
        #expect(try db.loadEntries() == [])
    }

    @Test func searchMatchesChineseSubstring() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/cn.md", type: "paper-analysis", title: "量表",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "拨号量表与感官"),
            (path: "vault/papers/en.md", type: "paper-analysis", title: "Dial",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "dial gauge senses"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let cn = try db.search("量表", type: nil, minRating: nil, theme: nil, limit: 80)
        #expect(cn.map(\.entry.path) == ["vault/papers/cn.md"])
        let en = try db.search("gauge", type: nil, minRating: nil, theme: nil, limit: 80)
        #expect(en.map(\.entry.path) == ["vault/papers/en.md"])
    }

    @Test func searchRespectsTypeFilterAndLimit() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/p.md", type: "paper-analysis", title: "P",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "shared keyword"),
            (path: "vault/notes/n.md", type: "note", title: "N",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "shared keyword"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let onlyPapers = try db.search("shared", type: .paperAnalysis, minRating: nil, theme: nil, limit: 80)
        #expect(onlyPapers.map(\.entry.path) == ["vault/papers/p.md"])
        let limited = try db.search("shared", type: nil, minRating: nil, theme: nil, limit: 1)
        #expect(limited.count == 1)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd apple && swift test --filter IndexDatabaseTests`
Expected: FAIL — `cannot find 'IndexDatabase' in scope`.

- [ ] **Step 3: Implement `IndexDatabase`**

Create `apple/Sources/MarpleKit/IndexDatabase.swift`:

```swift
import Foundation
import GRDB

/// Read-only view of the SQLite index (`<workspaceRoot>/.marple/index.sqlite`)
/// that the background indexer maintains. Opens read-only with a busy timeout so
/// reads never collide with the indexer's WAL writes. All methods are best-effort:
/// a missing file or table yields empty results rather than throwing, so the app
/// degrades to "no metadata yet" instead of crashing on first run.
public struct IndexDatabase: Sendable {
    public let indexDBPath: String
    public init(indexDBPath: String) { self.indexDBPath = indexDBPath }

    private func openQueue() throws -> DatabaseQueue? {
        guard FileManager.default.fileExists(atPath: indexDBPath) else { return nil }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        return try DatabaseQueue(path: indexDBPath, configuration: config)
    }

    public func loadEntries() throws -> [Entry] {
        guard let queue = try openQueue() else { return [] }
        return try queue.read { db in
            guard try db.tableExists("entries") else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT path, type, book, title, author, year_json, rating_score,
                       themes_json, topic, source, doi, annotates, has_pdf, mtime, preview, added
                FROM entries
                """)
            return rows.map(Self.entry(from:))
        }
    }

    public func search(_ q: String, type: EntryType?, minRating: Double?,
                       theme: String?, limit: Int) throws -> [SearchHit] {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let queue = try openQueue() else { return [] }
        let match = Self.ftsPhrase(trimmed)
        return try queue.read { db in
            guard try db.tableExists("entry_trigram"), try db.tableExists("entries") else { return [] }
            var sql = """
                SELECT e.path AS path, e.type AS type, e.book AS book, e.title AS title,
                       e.author AS author, e.year_json AS year_json, e.rating_score AS rating_score,
                       e.themes_json AS themes_json, e.topic AS topic, e.source AS source,
                       e.doi AS doi, e.annotates AS annotates, e.has_pdf AS has_pdf,
                       e.mtime AS mtime, e.preview AS preview, e.added AS added,
                       bm25(entry_trigram) AS score,
                       snippet(entry_trigram, 2, '〔', '〕', '…', 8) AS snip
                FROM entry_trigram
                JOIN entries e ON e.path = entry_trigram.path
                WHERE entry_trigram MATCH ?
                """
            var args: [DatabaseValueConvertible] = [match]
            if let type { sql += "\n  AND e.type = ?"; args.append(type.rawValue) }
            if let minRating { sql += "\n  AND e.rating_score >= ?"; args.append(minRating) }
            if let theme {
                sql += "\n  AND e.path IN (SELECT path FROM entry_themes WHERE theme = ?)"
                args.append(theme)
            }
            sql += "\nORDER BY score\nLIMIT ?"
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                SearchHit(entry: Self.entry(from: row),
                          score: row["score"] ?? 0,
                          snippet: row["snip"],
                          source: "trigram")
            }
        }
    }

    /// Map one `entries` row (or a search-join row aliased to the same names) to `Entry`.
    static func entry(from row: Row) -> Entry {
        let themes: [String] = (row["themes_json"] as String?)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let year: String? = decodeYear(row["year_json"] as String?)
        let mtime: Double? = (row["mtime"] as Int64?).map(Double.init)
        let added: Double? = (row["added"] as Int64?).map(Double.init)
        return Entry(
            path: row["path"],
            type: EntryType(rawValue: row["type"]),
            title: row["title"],
            author: row["author"],
            year: year,
            ratingScore: row["rating_score"] ?? 0,
            themes: themes,
            preview: (row["preview"] as String?) ?? "",
            hasPDF: ((row["has_pdf"] as Int64?) ?? 0) != 0,
            mtime: mtime,
            added: added,
            source: row["source"],
            book: row["book"],
            topic: row["topic"],
            doi: row["doi"],
            annotates: row["annotates"]
        )
    }

    /// `year_json` holds a JSON scalar ("2014", 2014, 2014.0) or null. Mirror the
    /// HTTP path: stringify a scalar, drop anything else.
    static func decodeYear(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        if let s = try? JSONDecoder().decode(String.self, from: data) { return s }
        if let i = try? JSONDecoder().decode(Int.self, from: data) { return String(i) }
        if let d = try? JSONDecoder().decode(Double.self, from: data) { return String(Int(d)) }
        let raw = json.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return raw.isEmpty || raw == "null" ? nil : raw
    }

    /// Wrap user input as a single FTS5 phrase, doubling embedded quotes. Trigram
    /// matches it as a substring, so this is the CJK-safe form and also neutralizes
    /// FTS5 operators in the raw query.
    static func ftsPhrase(_ q: String) -> String {
        "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `cd apple && swift test --filter IndexDatabaseTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/IndexDatabase.swift apple/Tests/MarpleKitTests/IndexDatabaseTests.swift
git commit -m "feat(native): GRDB read layer over the SQLite index (loadEntries + trigram search)"
```

---

### Task 4: `LocalVaultClient` — file IO + delegate index/search

**Files:**
- Create: `apple/Sources/MarpleKit/LocalVaultClient.swift`
- Test: `apple/Tests/MarpleKitTests/LocalVaultClientTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `apple/Tests/MarpleKitTests/LocalVaultClientTests.swift`:

```swift
import Testing
import Foundation
@testable import MarpleKit

@Suite struct LocalVaultClientTests {
    /// A temp workspace with a vault/ dir and an empty index path.
    private func makeWorkspace() throws -> (root: String, client: LocalVaultClient) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("vault/papers"), withIntermediateDirectories: true)
        let index = IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path)
        return (root.path, LocalVaultClient(workspaceRoot: root.path, index: index))
    }

    @Test func entryTextReadsFileRelativeToWorkspace() async throws {
        let (root, client) = try makeWorkspace()
        let abs = URL(fileURLWithPath: root).appendingPathComponent("vault/papers/a.md")
        try "# Hello".write(to: abs, atomically: true, encoding: .utf8)
        let text = try await client.entryText(path: "vault/papers/a.md")
        #expect(text == "# Hello")
    }

    @Test func entryTextMissingThrowsNotFound() async throws {
        let (_, client) = try makeWorkspace()
        await #expect(throws: VaultError.notFound("vault/papers/nope.md")) {
            _ = try await client.entryText(path: "vault/papers/nope.md")
        }
    }

    @Test func writeFileWritesToDisk() async throws {
        let (root, client) = try makeWorkspace()
        try await client.writeFile(path: "vault/papers/a.md", text: "updated")
        let abs = URL(fileURLWithPath: root).appendingPathComponent("vault/papers/a.md")
        #expect(try String(contentsOf: abs, encoding: .utf8) == "updated")
    }

    @Test func createNoteCreatesParentDirsAndFile() async throws {
        let (root, client) = try makeWorkspace()
        try await client.createNote(path: "vault/notes/idea-1.md", text: "draft")
        let abs = URL(fileURLWithPath: root).appendingPathComponent("vault/notes/idea-1.md")
        #expect(try String(contentsOf: abs, encoding: .utf8) == "draft")
    }

    @Test func trashRoundTrip() async throws {
        let (root, client) = try makeWorkspace()
        try await client.createNote(path: "vault/notes/x.md", text: "bye")
        // move to trash
        let trashRel = try await client.moveToTrash(path: "vault/notes/x.md")
        #expect(trashRel.hasPrefix("vault/notes/.trash/"))
        let original = URL(fileURLWithPath: root).appendingPathComponent("vault/notes/x.md")
        #expect(FileManager.default.fileExists(atPath: original.path) == false)
        // list
        let items = try await client.listTrash()
        #expect(items.count == 1)
        let name = items[0].name
        #expect(name.hasPrefix("x.") && name.hasSuffix(".md"))
        // restore
        let restoredRel = try await client.restoreTrash(name: name)
        #expect(restoredRel == "vault/notes/x.md")
        #expect(FileManager.default.fileExists(atPath: original.path) == true)
        #expect(try await client.listTrash() == [])
    }

    @Test func purgeRemovesTrashItem() async throws {
        let (_, client) = try makeWorkspace()
        try await client.createNote(path: "vault/notes/y.md", text: "bye")
        _ = try await client.moveToTrash(path: "vault/notes/y.md")
        let name = try await client.listTrash()[0].name
        try await client.purgeTrash(name: name)
        #expect(try await client.listTrash() == [])
    }

    @Test func indexDelegatesToIndexDatabaseEmptyWhenNoDB() async throws {
        let (_, client) = try makeWorkspace()
        #expect(try await client.index() == [])
        #expect(try await client.search(SearchQuery(q: "anything")) == [])
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd apple && swift test --filter LocalVaultClientTests`
Expected: FAIL — `cannot find 'LocalVaultClient' in scope`.

- [ ] **Step 3: Implement `LocalVaultClient`**

Create `apple/Sources/MarpleKit/LocalVaultClient.swift`:

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// In-process `VaultClient`: reads/writes vault markdown files directly and
/// delegates metadata/search to `IndexDatabase`. No HTTP, no sidecar on the hot
/// path. All `path` arguments are workspace-relative (e.g. "vault/papers/x.md").
public struct LocalVaultClient: VaultClient {
    let workspaceRoot: String
    let index: IndexDatabase
    private let fm = FileManager.default

    public init(workspaceRoot: String, index: IndexDatabase) {
        self.workspaceRoot = workspaceRoot
        self.index = index
    }

    private func absURL(_ relPath: String) -> URL {
        URL(fileURLWithPath: workspaceRoot).appendingPathComponent(relPath)
    }
    private var trashDir: URL { absURL("vault/notes/.trash") }

    // MARK: metadata + search (delegate)

    public func index() async throws -> [Entry] { try index.loadEntries() }

    public func search(_ query: SearchQuery) async throws -> [SearchHit] {
        try index.search(query.q, type: query.type, minRating: query.minRating,
                         theme: query.theme, limit: query.limit)
    }

    // MARK: file IO

    public func entryText(path: String) async throws -> String {
        do { return try String(contentsOf: absURL(path), encoding: .utf8) }
        catch { throw VaultError.notFound(path) }
    }

    public func writeFile(path: String, text: String) async throws {
        try text.write(to: absURL(path), atomically: true, encoding: .utf8)
    }

    public func createNote(path: String, text: String) async throws {
        let url = absURL(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func openInEditor(path: String, app: String) async throws {
        #if canImport(AppKit)
        NSWorkspace.shared.open(absURL(path))
        #endif
    }

    // MARK: trash (file moves under vault/notes/.trash, name = "{base}.{ts}.md")

    public func moveToTrash(path: String) async throws -> String {
        let src = absURL(path)
        guard fm.fileExists(atPath: src.path) else { throw VaultError.notFound(path) }
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let base = src.deletingPathExtension().lastPathComponent
        let name = "\(base).\(Self.trashTimestamp()).md"
        let dest = trashDir.appendingPathComponent(name)
        try fm.moveItem(at: src, to: dest)
        return "vault/notes/.trash/\(name)"
    }

    public func listTrash() async throws -> [TrashItem] {
        guard let names = try? fm.contentsOfDirectory(atPath: trashDir.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.compactMap { name in
            let url = trashDir.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? Int) ?? 0
            let (base, ts) = Self.splitTrashName(name)
            return TrashItem(name: name, originalBase: base, ts: ts, mtime: mtime, size: size)
        }
    }

    public func restoreTrash(name: String) async throws -> String {
        let src = trashDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else { throw VaultError.notFound(name) }
        let (base, _) = Self.splitTrashName(name)
        let rel = "vault/notes/\(base ?? name).md"
        try fm.moveItem(at: src, to: absURL(rel))
        return rel
    }

    public func purgeTrash(name: String) async throws {
        let target = trashDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: target.path) else { throw VaultError.notFound(name) }
        try fm.removeItem(at: target)
    }

    // MARK: helpers

    /// Filesystem-safe, dot-free timestamp so `splitTrashName` can split on the
    /// last dot reliably.
    static func trashTimestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    /// "{base}.{ts}.md" -> (base, ts). Splits on the last dot of the stem, so a
    /// base containing dots is preserved.
    static func splitTrashName(_ name: String) -> (base: String?, ts: String?) {
        let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        guard let dot = stem.lastIndex(of: ".") else { return (stem, nil) }
        return (String(stem[..<dot]), String(stem[stem.index(after: dot)...]))
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `cd apple && swift test --filter LocalVaultClientTests`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Run the full Swift suite to confirm no regressions**

Run: `cd apple && swift test`
Expected: all green (existing suites + the two new ones).

- [ ] **Step 6: Commit**

```bash
git add apple/Sources/MarpleKit/LocalVaultClient.swift apple/Tests/MarpleKitTests/LocalVaultClientTests.swift
git commit -m "feat(native): LocalVaultClient — in-process file IO + index/search delegation"
```

---

### Task 5: Wire the app to `LocalVaultClient` and verify in the GUI

**Files:**
- Modify: `apple/Sources/Marple/MarpleApp.swift:16-21`

- [ ] **Step 1: Swap the client construction**

In `apple/Sources/Marple/MarpleApp.swift`, the current block (`:16-21`) launches the sidecar and builds an `HTTPVaultClient`. Keep the sidecar launch (it stays as the background indexer) but build a `LocalVaultClient` for the data path. Read the surrounding function first, then change the client construction. The two `HTTPVaultClient(baseURL: base)` / `AppModel(client:...)` lines become:

```swift
            let index = IndexDatabase(
                indexDBPath: paths.workspaceRoot + "/.marple/index.sqlite")
            let client = LocalVaultClient(workspaceRoot: paths.workspaceRoot, index: index)
            let m = AppModel(client: client, stateStore: UserDefaultsStateStore())
```

(Leave `let sidecar = SidecarProcess(...)` and its start call in place; the index still needs the watcher. The `base`/`baseURL` variable may now be unused — remove it only if the compiler flags it as unused, otherwise leave the sidecar wiring untouched.)

- [ ] **Step 2: Build the app**

Run: `cd apple && swift build`
Expected: builds clean. Fix any unused-variable warning by removing only the now-dead `baseURL` binding if present.

- [ ] **Step 3: Commit**

```bash
git add apple/Sources/Marple/MarpleApp.swift
git commit -m "feat(native): point the app's data path at LocalVaultClient (sidecar demoted to indexer)"
```

- [ ] **Step 4: GUI verification (manual — run by the human)**

This is the only step that needs a human at the GUI. Launch the app against the real vault and confirm:
- The entry list populates (metadata read in-process from the index).
- Opening a paper renders its body (file read in-process).
- Typing a Chinese query in search returns matches (trigram search in-process).
- Editing rating/year/themes in the inspector writes back and persists (file write in-process).
- Creating an idea note / annotation creates the file and opens it.
- Move-to-trash, the trash list, restore, and purge all behave.
- No `database is locked` in the log while the watcher reconciles after an edit.

Report any failure with the console log; treat a failure here as a new debugging task, not a plan step.

---

## Self-Review

**Spec coverage:**
- "File read/write should be process-level, not HTTP" → Tasks 3-4 (`LocalVaultClient` file IO). ✓
- "List metadata should read SQL directly" → Task 3 (`IndexDatabase.loadEntries`) + Task 4 delegation. ✓
- "Keyword search in-process, CJK-correct" → Task 3 (`search` over `entry_trigram`). ✓
- "Swappable store behind a protocol" → reuses the existing `VaultClient` protocol; `LocalVaultClient` is a drop-in conformer, swapped at one wiring line (Task 5). ✓
- "Don't reintroduce the lock bug" → Task 1 (WAL) + read-only busy-timeout opens. ✓
- All 10 `VaultClient` methods implemented in `LocalVaultClient` (index, entryText, search, openInEditor, writeFile, createNote, moveToTrash, listTrash, restoreTrash, purgeTrash). ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step has a run command + expected result.

**Type consistency:** `IndexDatabase.search(...)` returns `[SearchHit]`; `LocalVaultClient.search` maps `SearchQuery` → those params and returns the same. `entry(from:)` is the single row→`Entry` mapper used by both `loadEntries` and `search`. `splitTrashName`/`trashTimestamp` agree on the `{base}.{ts}.md` format. Method signatures match the `VaultClient` protocol in `VaultClient.swift`.

## Out of scope (separate future plans)

- **Phase 2 — port the indexer to Swift** (frontmatter/wikilink parse, FTS population, FSEvents-driven reconcile via GRDB `DatabasePool` as the single writer), then delete the sidecar and `SidecarProcess`. This is where the store fully becomes Swift-owned and the `cargo run` dependency disappears.
- **Phase 3 — semantic search** (BGE-M3 embeddings in Swift via CoreML/MLX, or a slim embedding-only sidecar).
