import Testing
import Foundation
import GRDB
@testable import MarpleKit

// QUA-119 migration & sanitization tests.
//
// These cover the bits that aren't tested by simply updating long-form
// literals to short forms in existing suites: schema_version gating in the
// indexer, cacheFormatVersion bump, persisted-state legacy sanitization, the
// unknown-type diagnostic, and short CLI digest output.

// MARK: - Schema version migration

@Suite("QUA-119: schema_version gates buildFull")
struct SchemaVersionMigrationTests {

    private func makeTempWorkspace() throws -> String {
        let root = NSTemporaryDirectory()
            + "marple-qua119-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/vault", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/sources", withIntermediateDirectories: true)
        return root
    }

    /// A DB that has all current `entries` columns but lacks the
    /// `meta.schema_version` row (pre-QUA-119 layout). `canSkipFullBuild`
    /// must say false so reconcile falls into `buildFull` rather than
    /// reading long-form rows under strict-short canonical rules.
    @Test("canSkipFullBuild is false when meta.schema_version is missing")
    func canSkipFalseOnMissingSchemaVersion() throws {
        let ws = try makeTempWorkspace()
        let marpleDir = ws + "/.marple"
        try FileManager.default.createDirectory(
            atPath: marpleDir, withIntermediateDirectories: true)
        let indexPath = marpleDir + "/index.sqlite"
        let queue = try DatabaseQueue(path: indexPath)
        try queue.write { db in
            // Full current `entries` shape so the column / retired-table
            // checks pass — the only stale signal is the missing
            // schema_version row.
            try db.execute(sql: """
                CREATE TABLE entries (
                  path TEXT PRIMARY KEY, type TEXT NOT NULL, book TEXT, title TEXT,
                  title_en TEXT, title_cn TEXT, author TEXT, year_json TEXT, rating_json TEXT,
                  rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, kind TEXT,
                  journal TEXT, source TEXT, doi TEXT, publisher TEXT, isbn TEXT, category TEXT,
                  translation_title_cn TEXT, translation_douban_url TEXT, chapters_analyzed INTEGER,
                  annotates TEXT, created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0,
                  mtime INTEGER, preview TEXT NOT NULL DEFAULT '', body_len INTEGER NOT NULL DEFAULT 0,
                  added INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO meta(key, value) VALUES ('entries_revision', '5');
                -- intentionally no schema_version row
                INSERT INTO entries (path, type) VALUES
                  ('vault/papers/legacy.md', 'paper-analysis');
                """)
        }

        let indexer = VaultIndexer(workspaceRoot: ws)
        #expect(indexer.canSkipFullBuild() == false)
    }

    /// `canSkipFullBuild` must also reject a DB whose schema_version is
    /// numerically older than the running build's `IndexWriter.schemaVersion`.
    @Test("canSkipFullBuild is false when meta.schema_version is older")
    func canSkipFalseOnOlderSchemaVersion() throws {
        let ws = try makeTempWorkspace()
        let marpleDir = ws + "/.marple"
        try FileManager.default.createDirectory(
            atPath: marpleDir, withIntermediateDirectories: true)
        let indexPath = marpleDir + "/index.sqlite"
        let queue = try DatabaseQueue(path: indexPath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE entries (
                  path TEXT PRIMARY KEY, type TEXT NOT NULL, book TEXT, title TEXT,
                  title_en TEXT, title_cn TEXT, author TEXT, year_json TEXT, rating_json TEXT,
                  rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, kind TEXT,
                  journal TEXT, source TEXT, doi TEXT, publisher TEXT, isbn TEXT, category TEXT,
                  translation_title_cn TEXT, translation_douban_url TEXT, chapters_analyzed INTEGER,
                  annotates TEXT, created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0,
                  mtime INTEGER, preview TEXT NOT NULL DEFAULT '', body_len INTEGER NOT NULL DEFAULT 0,
                  added INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO meta(key, value) VALUES ('schema_version', '1');
                """)
        }
        let indexer = VaultIndexer(workspaceRoot: ws)
        #expect(indexer.canSkipFullBuild() == false)
    }

    /// `buildFull` must persist the current `schema_version` so the next boot
    /// short-circuits to `canSkipFullBuild()==true`.
    @Test("buildFull writes meta.schema_version and canSkipFullBuild flips to true")
    func buildFullPersistsSchemaVersion() throws {
        let ws = try makeTempWorkspace()
        let papersDir = ws + "/vault/papers"
        try FileManager.default.createDirectory(
            atPath: papersDir, withIntermediateDirectories: true)
        let md = """
        ---
        type: paper
        title: Hello
        ---
        Body.
        """
        try md.write(toFile: papersDir + "/hello.md", atomically: true, encoding: .utf8)

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let queue = try DatabaseQueue(path: ws + "/.marple/index.sqlite")
        let v = try queue.read { db in try IndexWriter.schemaVersion(db) }
        #expect(v == IndexWriter.schemaVersion)
        #expect(indexer.canSkipFullBuild() == true)
    }

    /// End-to-end: a pre-QUA-119 DB carrying a long-form row must be rebuilt
    /// (not read in place), and after the rebuild the row holds the short form
    /// produced by `canonicalType`.
    @Test("reconcile rebuilds a pre-QUA-119 DB and writes only short-form types")
    func reconcileRebuildsLegacyDB() throws {
        let ws = try makeTempWorkspace()
        let papersDir = ws + "/vault/papers"
        try FileManager.default.createDirectory(
            atPath: papersDir, withIntermediateDirectories: true)
        // The on-disk vault uses short canonical form (the issue scopes vault
        // content explicitly out of bounds; vault is already migrated).
        let md = """
        ---
        type: paper
        title: Reborn
        ---
        Body.
        """
        try md.write(toFile: papersDir + "/reborn.md", atomically: true, encoding: .utf8)

        // Plant a pre-QUA-119 DB with the long-form row.
        let marpleDir = ws + "/.marple"
        try FileManager.default.createDirectory(
            atPath: marpleDir, withIntermediateDirectories: true)
        let indexPath = marpleDir + "/index.sqlite"
        let plant = try DatabaseQueue(path: indexPath)
        try plant.write { db in
            try db.execute(sql: """
                CREATE TABLE entries (
                  path TEXT PRIMARY KEY, type TEXT NOT NULL, book TEXT, title TEXT,
                  title_en TEXT, title_cn TEXT, author TEXT, year_json TEXT, rating_json TEXT,
                  rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, kind TEXT,
                  journal TEXT, source TEXT, doi TEXT, publisher TEXT, isbn TEXT, category TEXT,
                  translation_title_cn TEXT, translation_douban_url TEXT, chapters_analyzed INTEGER,
                  annotates TEXT, created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0,
                  mtime INTEGER, preview TEXT NOT NULL DEFAULT '', body_len INTEGER NOT NULL DEFAULT 0,
                  added INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO entries (path, type, title) VALUES
                  ('vault/papers/reborn.md', 'paper-analysis', 'Reborn');
                """)
        }

        let indexer = VaultIndexer(workspaceRoot: ws)
        let stats = try indexer.reconcile()
        // Stale schema → full rebuild → 1 upsert from the .md file.
        #expect(stats.upserted == 1)

        let q = try DatabaseQueue(path: indexPath)
        let types = try q.read { db in
            try String.fetchAll(db, sql: "SELECT type FROM entries")
        }
        #expect(types == ["paper"], "rebuilt entries must hold short canonical type")
        let version = try q.read { db in try IndexWriter.schemaVersion(db) }
        #expect(version == IndexWriter.schemaVersion)
    }
}

// MARK: - Unknown-type diagnostic

@Suite("QUA-119: unknown-type diagnostic")
struct UnknownTypeReporterTests {

    /// Run `work` under a task-local override that captures every reported
    /// unknown-type incident. Because the override is `@TaskLocal`, parallel
    /// `@Test` cases each see their own capture and don't race over the
    /// global default.
    private func capturingReports(_ work: () -> Void) -> [UnknownTypeReport] {
        let collector = Collector()
        UnknownTypeReporter.$override.withValue({ report in
            collector.append(report)
        }) {
            work()
        }
        return collector.reports
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _reports: [UnknownTypeReport] = []
        var reports: [UnknownTypeReport] {
            lock.lock(); defer { lock.unlock() }
            return _reports
        }
        func append(_ r: UnknownTypeReport) {
            lock.lock(); defer { lock.unlock() }
            _reports.append(r)
        }
    }

    @Test("legacy long type surfaces a report with its raw value + path")
    func legacyLongFormReports() {
        let md = """
        ---
        type: paper-analysis
        title: Stale
        ---
        Body.
        """
        let reports = capturingReports {
            _ = buildIndexedEntry(
                text: md,
                rel: "vault/papers/stale.md",
                fileStem: "stale",
                sourceSlugs: [],
                mtimeMs: nil
            )
        }
        #expect(reports == [
            UnknownTypeReport(path: "vault/papers/stale.md", rawType: "paper-analysis"),
        ])
    }

    @Test("'A' sentinel and unknown experimental types both report")
    func sentinelAndExperimentalReport() {
        let docs: [(String, String, String)] = [
            ("vault/n/a.md", "A", "A"),
            ("vault/n/r.md", "topic-reading-list", "topic-reading-list"),
        ]
        let reports = capturingReports {
            for (path, type, _) in docs {
                let md = "---\ntype: \(type)\ntitle: x\n---\nBody."
                _ = buildIndexedEntry(text: md, rel: path, fileStem: "x",
                                      sourceSlugs: [], mtimeMs: nil)
            }
        }
        #expect(reports.count == 2)
        #expect(reports.map(\.rawType) == ["A", "topic-reading-list"])
        #expect(reports.map(\.path) == ["vault/n/a.md", "vault/n/r.md"])
    }

    @Test("recognized short types produce no report")
    func recognizedTypesQuiet() {
        let reports = capturingReports {
            for short in ["paper", "book", "chapter", "author",
                          "topic", "journal", "note", "image"] {
                let md = "---\ntype: \(short)\ntitle: x\n---\nBody."
                _ = buildIndexedEntry(text: md, rel: "vault/x/\(short).md",
                                      fileStem: short,
                                      sourceSlugs: [], mtimeMs: nil)
            }
        }
        #expect(reports.isEmpty)
    }
}

// MARK: - cacheFormatVersion bump

@Suite("QUA-119: entries.cache version")
struct EntriesCacheVersionTests {

    private func makeTempWorkspace() throws -> String {
        let root = NSTemporaryDirectory()
            + "marple-qua119-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/.marple", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/vault/papers", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/sources", withIntermediateDirectories: true)
        return root
    }

    /// Plant a sidecar that has the correct MARPLE magic header but a v1
    /// version byte. `loadEntries` must reject it on read; the file is
    /// either deleted by the readCache error-path or asynchronously
    /// overwritten by the post-SQL cache rewrite. Either way, the file
    /// must no longer be a v1 sidecar after loadEntries returns.
    @Test("entries.cache v1 file is rejected by loadEntries (and any rewrite is v2)")
    func v1CacheRejected() throws {
        let ws = try makeTempWorkspace()

        // Set up an empty index DB.
        let indexPath = ws + "/.marple/index.sqlite"
        let q = try DatabaseQueue(path: indexPath)
        try q.write { db in try IndexWriter.createSchema(db) }

        // Plant a v1 sidecar: magic + version byte 1.
        let magic: [UInt8] = [0x4D, 0x41, 0x52, 0x50, 0x4C, 0x45, 0x00, 0x43]
        var header = Data(magic)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: Int64(0).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian, Array.init))
        let cachePath = ws + "/.marple/entries.cache"
        try header.write(to: URL(fileURLWithPath: cachePath))

        // loadEntries returns the SQL result (empty here); v1 cache was
        // either deleted or scheduled to be overwritten by an async rewrite.
        let db = IndexDatabase(indexDBPath: indexPath)
        let entries = try db.loadEntries()
        #expect(entries.isEmpty)

        // Wait briefly for the async cache rewrite to settle, then verify
        // the on-disk state is no longer a v1 sidecar. Two acceptable
        // outcomes: the file is absent, OR it exists with the v2 header.
        // Either proves we won't read v1 bytes on the next boot.
        let deadline = Date().addingTimeInterval(2.0)
        var settled = false
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: cachePath) {
                settled = true; break
            }
            if let on = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
               on.count >= 12 {
                let versionBytes = on.subdata(in: 8..<12)
                let v: UInt32 = versionBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
                if v == 2 { settled = true; break }
            }
            // Yield rather than block: the rewrite runs on a utility queue.
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(settled, "expected v1 cache to be either deleted or rewritten as v2")
    }
}

// MARK: - Persisted-state sanitization

@Suite("QUA-119: persisted state legacy sanitization")
struct PersistedStateLegacySanitizationTests {

    /// Encode a PersistedState whose internal fields look pre-QUA-119:
    /// long-form pane, long-form cachedType, long-form `counts` key. Decoding
    /// must drop the legacy bits so the in-memory state is clean.
    @Test("legacy long-form persisted state is sanitized on decode")
    func legacyStateDecodesClean() throws {
        // Build a synthetic state via low-level keyed encoding so we get the
        // exact JSON shape a pre-QUA-119 build would have produced. We do this
        // by re-encoding from a struct that uses `.other(rawValue:)` cases —
        // those flow through Codable identically to the production long-form
        // case the legacy code would emit.
        let legacy = PersistedState(
            browsePane: .type(.other("paper-analysis")),
            isBrowsing: true,
            tabs: [
                PersistedTab(
                    location: NavLocation(pane: .type(.other("book-overview")),
                                          openPath: "vault/books/x.md"),
                    pinned: false,
                    customTitle: nil,
                    cachedTitle: "Legacy Title",
                    cachedType: .other("paper-analysis")
                ),
                PersistedTab(
                    location: NavLocation(pane: .type(.paper),
                                          openPath: "vault/papers/clean.md"),
                    pinned: true,
                    cachedType: .paper
                ),
            ],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "list",
            currentSpace: nil,
            counts: [.other("paper-analysis"): 7, .note: 12, .other("topic-synthesis"): 4]
        )
        let blob = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: blob)

        // browsePane: stale → first modeled (.paper).
        #expect(decoded.browsePane == .type(.paper))

        // Tab 0: legacy pane + legacy cachedType both sanitized.
        #expect(decoded.tabs[0].location.pane == .type(.paper))
        #expect(decoded.tabs[0].location.openPath == "vault/books/x.md")
        #expect(decoded.tabs[0].cachedTitle == "Legacy Title")
        #expect(decoded.tabs[0].cachedType == nil)

        // Tab 1: was clean, must round-trip unchanged.
        #expect(decoded.tabs[1].location.pane == .type(.paper))
        #expect(decoded.tabs[1].cachedType == .paper)
        #expect(decoded.tabs[1].pinned)

        // counts: legacy keys filtered out, modeled keys preserved.
        #expect(decoded.counts == [.note: 12])
    }

    /// AppModel's `marple.typeOrder` UserDefaults blob can hold long-form
    /// rawValues. The model must filter them so the sidebar never paints
    /// an unknown bucket.
    @Test("type-order array filters .other(_) entries")
    func typeOrderFiltersLegacy() throws {
        let legacy: [EntryType] = [
            .other("paper-analysis"), .book, .other("topic-synthesis"), .author,
        ]
        let blob = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode([EntryType].self, from: blob)
        // Same logic AppModel.loadTypeOrder runs (kept inline so we don't
        // need to bring AppModel into the test target).
        var order = decoded.filter { $0.isModeled }
        for t in EntryType.modeled where !order.contains(t) { order.append(t) }
        #expect(order.allSatisfy { $0.isModeled })
        // All eight modeled types must end up represented.
        for t in EntryType.modeled {
            #expect(order.contains(t))
        }
    }
}

// MARK: - Search filter guards .other(_)

@Suite("QUA-119: IndexDatabase.search ignores .other(_) type filter")
struct SearchOtherTypeGuardTests {

    private func makeWorkspace() throws -> String {
        let root = NSTemporaryDirectory()
            + "marple-qua119-search-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/.marple", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/vault/papers", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/sources", withIntermediateDirectories: true)
        return root
    }

    /// A `.other("paper-analysis")` programmatically passed to `search` (not
    /// through PersistedState, which sanitizes it away) must not become an
    /// `e.type = 'paper-analysis'` SQL filter that returns zero rows. The
    /// guard short-circuits the type filter so the text query still produces
    /// hits — better fallback than a silent empty result.
    @Test("search with .other(_) type returns rows matching the text query")
    func searchOtherTypeFallsBackToTextOnly() throws {
        let ws = try makeWorkspace()
        let papersDir = ws + "/vault/papers"
        let md = """
        ---
        type: paper
        title: Findable Title
        ---
        Body content with the word repair in it.
        """
        try md.write(toFile: papersDir + "/findable.md", atomically: true, encoding: .utf8)

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let db = IndexDatabase(indexDBPath: ws + "/.marple/index.sqlite")
        // Sanity: known short type filter works.
        let paperHits = try db.search("repair", type: .paper,
                                      minRating: nil, theme: nil, limit: 80)
        #expect(paperHits.count == 1)
        // The guard: an unknown type does not silence the search; the text
        // query still finds the row.
        let otherHits = try db.search("repair", type: .other("paper-analysis"),
                                      minRating: nil, theme: nil, limit: 80)
        #expect(otherHits.count == 1,
                "guard should drop the unknown-type filter, not zero out the result")
    }
}

// MARK: - CLI digest short forms

@Suite("QUA-119: CLI EntryDigest emits short forms")
struct CLIShortFormDigestTests {

    @Test("EntryDigest carries the EntryType rawValue verbatim — short form")
    func entryDigestUsesShortRawValue() {
        // Constructing EntryDigest directly mirrors what `CLIHandlers.toDigest`
        // does at runtime (entry.type.rawValue). After QUA-119 the rawValue
        // for the eight modeled types is always the short canonical string.
        for short in ["paper", "book", "chapter", "author",
                      "topic", "journal", "note", "image"] {
            let t = EntryType(rawValue: short)
            let digest = EntryDigest(path: "vault/x/\(short).md",
                                     title: "x", type: t.rawValue,
                                     themes: [], author: [],
                                     year: nil, mtime: nil)
            #expect(digest.type == short)
        }
    }
}
