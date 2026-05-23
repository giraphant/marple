# marple-native P4 — File management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add create-note / create-annotation, soft-delete to trash, and a 回收站 (restore / purge) view to the native macOS reader, mirroring the web app's file-management behavior.

**Architecture:** All work is Swift-side in `apple/` — the Rust `reader-api` already exposes every endpoint (`POST /vault/*` create, `DELETE /vault/*` → trash, `GET/POST/DELETE /api/trash`). Pure logic (a `NoteBuilder`, a `TrashItem` DTO, `Pane.trash`) lands in the `MarpleKit` library under TDD; `AppModel` actions and SwiftUI surfaces land in the `Marple` executable and are build-verified + GUI-validated (the executable has no test target, matching the existing pattern).

**Tech Stack:** Swift 6 / SwiftUI / `@Observable`; swift-testing (`import Testing`); URLSession; macOS 14+.

**Spec:** `docs/superpowers/specs/2026-05-23-marple-native-p4-design.md`

---

## Conventions for every task

- **All commands run from `/Users/ramudai/Documents/Learn/marple/apple`.**
- **Run the MarpleKit tests with the framework flags** (bare `swift test` fails with `no such module 'Testing'` on these Command Line Tools):
  ```
  swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  ```
  Append `--filter <SuiteName>` to scope to one suite.
- **Build the whole package (incl. the executable) with:** `swift build`
- **Commit discipline:** stage only the files named in the step (`git add <paths>`), never `git add -A`. Co-author trailer:
  ```
  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```
- The repo has unrelated pre-existing modifications to web files (`index.html`, `src-tauri/tauri.conf.json`, `src/components/*`) and an untracked `docs/superpowers/specs/2026-05-23-marple-native-layout-spec.md`. **Do not stage or touch those.**

## File structure

**Create (MarpleKit):**
- `Sources/MarpleKit/TrashItem.swift` — the trash DTO (Task 1)
- `Sources/MarpleKit/NoteBuilder.swift` — pure idea/annotation draft builder (Task 2)
- `Tests/MarpleKitTests/TrashItemTests.swift` (Task 1)
- `Tests/MarpleKitTests/NoteBuilderTests.swift` (Task 2)

**Create (Marple executable):**
- `Sources/Marple/TrashView.swift` — the 回收站 view (Task 6)

**Modify (MarpleKit):**
- `Sources/MarpleKit/VaultClient.swift` — protocol + `StubVaultClient` (Tasks 3)
- `Sources/MarpleKit/HTTPVaultClient.swift` — 5 new methods (Tasks 3, 4)
- `Sources/MarpleKit/Browse.swift` — `Pane.trash` (Task 6)
- `Tests/MarpleKitTests/VaultClientStubTests.swift` (Task 3)
- `Tests/MarpleKitTests/HTTPVaultClientTests.swift` (Task 4)
- `Tests/MarpleKitTests/BrowseTests.swift` (Task 6)

**Modify (Marple executable):**
- `Sources/Marple/AppModel.swift` — trash state + actions (Task 5), note creation (Task 7)
- `Sources/Marple/SidebarView.swift` — 回收站 row (Task 6), 新建笔记 button (Task 8)
- `Sources/Marple/RootView.swift` — trash routing (Task 6)
- `Sources/Marple/EntryListView.swift` — `.trash` title case + context menu (Tasks 6, 8)
- `Sources/Marple/DocView.swift` — 新建批注 + `+` toolbar items (Task 8)
- `Sources/Marple/TabCommands.swift` — ⌘N 新建笔记 (Task 8)

---

## Task 1: `TrashItem` DTO (MarpleKit)

**Files:**
- Create: `Sources/MarpleKit/TrashItem.swift`
- Test: `Tests/MarpleKitTests/TrashItemTests.swift`

The JSON from `GET /api/trash` is `{ "items": [ { name, originalBase, ts, mtime, size } ] }`. Keys verified against `rust/reader-core/src/lib.rs` (`originalBase` is serde-renamed to camelCase), so default `Decodable` works with no `CodingKeys`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MarpleKitTests/TrashItemTests.swift`:

```swift
import Testing
import Foundation
@testable import MarpleKit

@Suite struct TrashItemTests {
    @Test func testDecodesTrashListPayload() throws {
        let json = #"{"items":[{"name":"my-note.2026-05-23T10-00-00-000Z.md","originalBase":"my-note","ts":"2026-05-23T10-00-00-000Z","mtime":1716460800.0,"size":42}]}"#
        struct Wrapper: Decodable { let items: [TrashItem] }
        let items = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).items
        #expect(items.count == 1)
        #expect(items[0].name == "my-note.2026-05-23T10-00-00-000Z.md")
        #expect(items[0].originalBase == "my-note")
        #expect(items[0].ts == "2026-05-23T10-00-00-000Z")
        #expect(items[0].mtime == 1716460800.0)
        #expect(items[0].size == 42)
        #expect(items[0].id == items[0].name)
    }

    @Test func testDecodesNullOriginalBase() throws {
        let json = #"{"name":"weird.md","originalBase":null,"ts":null,"mtime":1.0,"size":0}"#
        let item = try JSONDecoder().decode(TrashItem.self, from: Data(json.utf8))
        #expect(item.originalBase == nil)
        #expect(item.ts == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter TrashItemTests`
Expected: FAIL — compile error "cannot find type 'TrashItem' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/MarpleKit/TrashItem.swift`:

```swift
import Foundation

/// One soft-deleted file in `vault/notes/.trash/`, as returned by `GET /api/trash`.
public struct TrashItem: Sendable, Equatable, Identifiable, Decodable {
    public let name: String          // "<base>.<iso-ts>.md"
    public let originalBase: String?
    public let ts: String?
    public let mtime: Double
    public let size: Int
    public var id: String { name }

    public init(name: String, originalBase: String?, ts: String?, mtime: Double, size: Int) {
        self.name = name
        self.originalBase = originalBase
        self.ts = ts
        self.mtime = mtime
        self.size = size
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter TrashItemTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MarpleKit/TrashItem.swift Tests/MarpleKitTests/TrashItemTests.swift
git commit -m "$(cat <<'EOF'
feat(native): TrashItem DTO for /api/trash

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `NoteBuilder` pure draft builder (MarpleKit)

**Files:**
- Create: `Sources/MarpleKit/NoteBuilder.swift`
- Test: `Tests/MarpleKitTests/NoteBuilderTests.swift`

Ports `newIdeaDraft` / `newAnnotationDraft` / `slugify` from `src/api.ts`. `today` and `stamp` are injectable so tests assert exact output. The title is rendered with `FrontmatterPatch.yamlScalar` (internal to MarpleKit, so directly callable) — it quotes only when YAML requires it (e.g. a title containing `": "`).

- [ ] **Step 1: Write the failing test**

Create `Tests/MarpleKitTests/NoteBuilderTests.swift`:

```swift
import Testing
import Foundation
@testable import MarpleKit

@Suite struct NoteBuilderTests {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test func testIdeaNotePathAndFrontmatter() {
        let d = NoteBuilder.ideaNote(today: date(2026, 5, 23), stamp: "abcd")
        #expect(d.path == "vault/notes/2026-05-23-idea-abcd.md")
        #expect(d.title == "2026-05-23 — 新笔记")
        #expect(d.text.hasPrefix("---\n"))
        #expect(d.text.contains("type: note\n"))
        #expect(d.text.contains("created: 2026-05-23\n"))
        #expect(d.text.contains("themes: []\n"))
        #expect(d.text.contains("# 2026-05-23 — 新笔记"))
    }

    @Test func testAnnotationTargetsEntry() {
        let target = Entry(path: "vault/papers/marx-1867.md", type: .paperAnalysis,
                           title: "Capital", author: nil, year: nil, ratingScore: 0,
                           themes: [], preview: "", hasPDF: false)
        let d = NoteBuilder.annotation(target: target, today: date(2026, 5, 23), stamp: "wxyz")
        #expect(d.path == "vault/notes/marx-1867-note-wxyz.md")
        #expect(d.title == "对《Capital》的批注")
        #expect(d.text.contains("type: note\n"))
        #expect(d.text.contains("annotates: vault/papers/marx-1867.md\n"))
    }

    @Test func testAnnotationTitleFallsBackToFilenameStem() {
        let target = Entry(path: "vault/notes/loose-idea.md", type: .note,
                           title: nil, author: nil, year: nil, ratingScore: 0,
                           themes: [], preview: "", hasPDF: false)
        let d = NoteBuilder.annotation(target: target, today: date(2026, 5, 23), stamp: "0000")
        #expect(d.title == "对《loose-idea》的批注")
        #expect(d.path == "vault/notes/loose-idea-note-0000.md")
    }

    @Test func testAnnotationTitleWithColonIsQuoted() {
        let target = Entry(path: "vault/papers/x.md", type: .paperAnalysis,
                           title: "Marx: Capital", author: nil, year: nil, ratingScore: 0,
                           themes: [], preview: "", hasPDF: false)
        let d = NoteBuilder.annotation(target: target, today: date(2026, 5, 23), stamp: "0000")
        #expect(d.text.contains("title: \"对《Marx: Capital》的批注\"\n"))
    }

    @Test func testSlugifyCases() {
        #expect(NoteBuilder.slugify("Hello World") == "hello-world")
        #expect(NoteBuilder.slugify("a--b__c") == "a-b__c")
        #expect(NoteBuilder.slugify("中文标题") == "note")
        #expect(NoteBuilder.slugify("--trim--") == "trim")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter NoteBuilderTests`
Expected: FAIL — compile error "cannot find 'NoteBuilder' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/MarpleKit/NoteBuilder.swift`:

```swift
import Foundation

/// A new note's destination path, full file text, and human title.
public struct NoteDraft: Equatable, Sendable {
    public let path: String
    public let text: String
    public let title: String
    public init(path: String, text: String, title: String) {
        self.path = path; self.text = text; self.title = title
    }
}

/// Builds new-note drafts. Pure; `today`/`stamp` injectable for deterministic tests.
/// Mirrors src/api.ts newIdeaDraft / newAnnotationDraft / slugify.
public enum NoteBuilder {
    static let notesDir = "vault/notes/"

    /// Standalone idea note: vault/notes/<date>-idea-<stamp>.md
    public static func ideaNote(today: Date = Date(),
                                stamp: String = NoteBuilder.stamp()) -> NoteDraft {
        let date = isoDate(today)
        let path = "\(notesDir)\(date)-idea-\(stamp).md"
        let title = "\(date) — 新笔记"
        let text = """
        ---
        type: note
        title: \(FrontmatterPatch.yamlScalar(title))
        created: \(date)
        themes: []
        ---

        # \(title)


        """
        return NoteDraft(path: path, text: text, title: title)
    }

    /// Annotation note targeting `target`: vault/notes/<slug>-note-<stamp>.md
    public static func annotation(target: Entry, today: Date = Date(),
                                  stamp: String = NoteBuilder.stamp()) -> NoteDraft {
        let date = isoDate(today)
        let stem = (target.path as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
        let slug = slugify(stem)
        let path = "\(notesDir)\(slug)-note-\(stamp).md"
        let title = "对《\(target.title ?? stem)》的批注"
        let text = """
        ---
        type: note
        title: \(FrontmatterPatch.yamlScalar(title))
        annotates: \(target.path)
        created: \(date)
        themes: []
        ---

        # \(title)


        """
        return NoteDraft(path: path, text: text, title: title)
    }

    /// Last 4 base-36 chars of the current epoch-ms (matches the web stamp).
    static func stamp() -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        return String(String(ms, radix: 36).suffix(4))
    }

    /// UTC yyyy-MM-dd (matches `new Date().toISOString().slice(0,10)`).
    static func isoDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Port of src/api.ts slugify: lowercase, non-[a-z0-9_] runs → "-",
    /// trim "-", cap 60, fallback "note".
    static func slugify(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        var out = ""
        var prevDash = false
        for ch in s.lowercased() {
            if allowed.contains(ch) {
                out.append(ch); prevDash = false
            } else if !prevDash {
                out.append("-"); prevDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        out = String(out.prefix(60))
        return out.isEmpty ? "note" : out
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter NoteBuilderTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MarpleKit/NoteBuilder.swift Tests/MarpleKitTests/NoteBuilderTests.swift
git commit -m "$(cat <<'EOF'
feat(native): NoteBuilder for idea/annotation drafts

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `VaultClient` protocol + `StubVaultClient` (MarpleKit)

**Files:**
- Modify: `Sources/MarpleKit/VaultClient.swift`
- Modify: `Sources/MarpleKit/HTTPVaultClient.swift` (placeholder bodies so the module compiles; real impl is Task 4)
- Test: `Tests/MarpleKitTests/VaultClientStubTests.swift`

Adds the five file-management methods to the protocol. `StubVaultClient` gets real, assertable implementations now; `HTTPVaultClient` gets throwing placeholders so the module compiles, replaced under TDD in Task 4.

- [ ] **Step 1: Write the failing test**

Append to `Tests/MarpleKitTests/VaultClientStubTests.swift` (inside the `VaultClientStubTests` suite, before the closing brace):

```swift
    @Test func testStubRecordsCreateNote() async throws {
        let stub = StubVaultClient(entries: [], texts: [:])
        try await stub.createNote(path: "vault/notes/n.md", text: "body")
        #expect(stub.createLog.created.first?.path == "vault/notes/n.md")
        #expect(stub.createLog.created.first?.text == "body")
    }

    @Test func testStubTrashLifecycle() async throws {
        let item = TrashItem(name: "n.2026.md", originalBase: "n", ts: "2026", mtime: 1, size: 3)
        let stub = StubVaultClient(entries: [], texts: [:], trashItems: [item])
        _ = try await stub.moveToTrash(path: "vault/notes/m.md")
        #expect(stub.trash.moved == ["vault/notes/m.md"])
        #expect(try await stub.listTrash().map(\.name) == ["n.2026.md"])
        _ = try await stub.restoreTrash(name: "n.2026.md")
        #expect(stub.trash.restored == ["n.2026.md"])
        #expect(try await stub.listTrash().isEmpty)
    }

    @Test func testStubPurge() async throws {
        let item = TrashItem(name: "n.2026.md", originalBase: "n", ts: "2026", mtime: 1, size: 3)
        let stub = StubVaultClient(entries: [], texts: [:], trashItems: [item])
        try await stub.purgeTrash(name: "n.2026.md")
        #expect(stub.trash.purged == ["n.2026.md"])
        #expect(try await stub.listTrash().isEmpty)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter VaultClientStubTests`
Expected: FAIL — compile errors ("value of type 'StubVaultClient' has no member 'createNote'/'createLog'/'trash'", "extra argument 'trashItems'").

- [ ] **Step 3: Extend the protocol**

In `Sources/MarpleKit/VaultClient.swift`, add the five methods to the `VaultClient` protocol body (after `writeFile`):

```swift
public protocol VaultClient: Sendable {
    func index() async throws -> [Entry]
    func entryText(path: String) async throws -> String
    func search(_ query: SearchQuery) async throws -> [SearchHit]
    func openInEditor(path: String, app: String) async throws
    func writeFile(path: String, text: String) async throws
    func createNote(path: String, text: String) async throws
    func moveToTrash(path: String) async throws -> String
    func listTrash() async throws -> [TrashItem]
    func restoreTrash(name: String) async throws -> String
    func purgeTrash(name: String) async throws
}
```

- [ ] **Step 4: Add the stub logs and trash store**

In `Sources/MarpleKit/VaultClient.swift`, after the existing `WriteLog` class, add:

```swift
/// Records created notes so stub-backed tests can assert on them.
public final class CreateLog: @unchecked Sendable {
    public private(set) var created: [(path: String, text: String)] = []
    public init() {}
    public func record(_ path: String, _ text: String) { created.append((path, text)) }
}

/// In-memory trash for the stub: seeded items + a log of operations.
public final class TrashStore: @unchecked Sendable {
    public private(set) var items: [TrashItem]
    public private(set) var moved: [String] = []
    public private(set) var restored: [String] = []
    public private(set) var purged: [String] = []
    public init(_ items: [TrashItem] = []) { self.items = items }
    public func move(_ path: String) { moved.append(path) }
    public func restore(_ name: String) { restored.append(name); items.removeAll { $0.name == name } }
    public func purge(_ name: String) { purged.append(name); items.removeAll { $0.name == name } }
}
```

- [ ] **Step 5: Implement the stub methods**

In `Sources/MarpleKit/VaultClient.swift`, update `StubVaultClient`. Add the two stored properties and a `trashItems` init parameter, and the five methods. The struct becomes:

```swift
public struct StubVaultClient: VaultClient {
    public let entries: [Entry]
    public let texts: [String: String]
    public let hits: [SearchHit]
    public let writeLog = WriteLog()
    public let createLog = CreateLog()
    public let trash: TrashStore
    public init(entries: [Entry], texts: [String: String], hits: [SearchHit] = [],
                trashItems: [TrashItem] = []) {
        self.entries = entries; self.texts = texts; self.hits = hits
        self.trash = TrashStore(trashItems)
    }
    public func index() async throws -> [Entry] { entries }
    public func entryText(path: String) async throws -> String {
        guard let t = texts[path] else { throw VaultError.notFound(path) }
        return t
    }
    public func search(_ query: SearchQuery) async throws -> [SearchHit] { hits }
    public func openInEditor(path: String, app: String) async throws {}
    public func writeFile(path: String, text: String) async throws { writeLog.record(path, text) }
    public func createNote(path: String, text: String) async throws { createLog.record(path, text) }
    public func moveToTrash(path: String) async throws -> String {
        trash.move(path); return "vault/notes/.trash/stub.md"
    }
    public func listTrash() async throws -> [TrashItem] { trash.items }
    public func restoreTrash(name: String) async throws -> String {
        trash.restore(name); return "vault/notes/\(name)"
    }
    public func purgeTrash(name: String) async throws { trash.purge(name) }
}
```

- [ ] **Step 6: Add placeholder bodies to `HTTPVaultClient` so the module compiles**

In `Sources/MarpleKit/HTTPVaultClient.swift`, before the final closing brace, add (these throw rather than crash; Task 4 replaces them with real implementations):

```swift
    // Implemented under TDD in Task 4.
    public func createNote(path: String, text: String) async throws {
        throw VaultError.backendUnavailable
    }
    public func moveToTrash(path: String) async throws -> String {
        throw VaultError.backendUnavailable
    }
    public func listTrash() async throws -> [TrashItem] {
        throw VaultError.backendUnavailable
    }
    public func restoreTrash(name: String) async throws -> String {
        throw VaultError.backendUnavailable
    }
    public func purgeTrash(name: String) async throws {
        throw VaultError.backendUnavailable
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter VaultClientStubTests`
Expected: PASS (original 3 + new 3 = 6 tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/MarpleKit/VaultClient.swift Sources/MarpleKit/HTTPVaultClient.swift Tests/MarpleKitTests/VaultClientStubTests.swift
git commit -m "$(cat <<'EOF'
feat(native): VaultClient trash + create-note surface (stub impl)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `HTTPVaultClient` file-management methods (MarpleKit)

**Files:**
- Modify: `Sources/MarpleKit/HTTPVaultClient.swift` (replace the Task 3 placeholders)
- Test: `Tests/MarpleKitTests/HTTPVaultClientTests.swift`

TDD the wire format with the existing `StubURLProtocol` harness. `createNote` POSTs (vs `writeFile`'s PUT); `moveToTrash` DELETEs `/vault/*` and decodes `{ trash }`; trash-name segments are percent-encoded.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MarpleKitTests/HTTPVaultClientTests.swift` (inside the `HTTPVaultClientTests` suite, before the closing brace):

```swift
    @Test func testCreateNotePostsText() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/vault/notes/new.md")
            #expect(String(decoding: req.bodyData(), as: UTF8.self) == "hello")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true,"path":"vault/notes/new.md"}"#.utf8))
        }
        try await makeClient().createNote(path: "vault/notes/new.md", text: "hello")
    }

    @Test func testMoveToTrashDeletesAndReturnsTrashPath() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.path == "/vault/notes/old.md")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true,"trash":"vault/notes/.trash/old.2026.md"}"#.utf8))
        }
        let p = try await makeClient().moveToTrash(path: "vault/notes/old.md")
        #expect(p == "vault/notes/.trash/old.2026.md")
    }

    @Test func testListTrashParsesItems() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/trash")
            let body = #"{"items":[{"name":"old.2026.md","originalBase":"old","ts":"2026","mtime":1.0,"size":5}]}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let items = try await makeClient().listTrash()
        #expect(items.map(\.name) == ["old.2026.md"])
    }

    @Test func testRestoreTrashPostsAndReturnsRestored() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/trash/old.2026.md/restore")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true,"restored":"vault/notes/old.md"}"#.utf8))
        }
        let r = try await makeClient().restoreTrash(name: "old.2026.md")
        #expect(r == "vault/notes/old.md")
    }

    @Test func testPurgeTrashDeletes() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.path == "/api/trash/old.2026.md")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        try await makeClient().purgeTrash(name: "old.2026.md")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter HTTPVaultClientTests`
Expected: FAIL — the new tests throw `VaultError.backendUnavailable` (from the Task 3 placeholders) instead of completing / returning the expected values.

- [ ] **Step 3: Replace the placeholders with real implementations**

In `Sources/MarpleKit/HTTPVaultClient.swift`, replace the five placeholder methods added in Task 3 with:

```swift
    public func createNote(path: String, text: String) async throws {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "POST"
        req.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(text.utf8)
        _ = try await run(req)
    }

    public func moveToTrash(path: String) async throws -> String {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "DELETE"
        let data = try await run(req)
        struct Resp: Decodable { let trash: String? }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.trash ?? ""
    }

    public func listTrash() async throws -> [TrashItem] {
        let data = try await get("api/trash")
        struct Wrapper: Decodable { let items: [TrashItem] }
        do { return try JSONDecoder().decode(Wrapper.self, from: data).items }
        catch { throw VaultError.decode("\(error)") }
    }

    public func restoreTrash(name: String) async throws -> String {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/api/trash/" + enc + "/restore")!)
        req.httpMethod = "POST"
        let data = try await run(req)
        struct Resp: Decodable { let restored: String? }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.restored ?? ""
    }

    public func purgeTrash(name: String) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/api/trash/" + enc)!)
        req.httpMethod = "DELETE"
        _ = try await run(req)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter HTTPVaultClientTests`
Expected: PASS (original 6 + new 5 = 11 tests).

- [ ] **Step 5: Run the full MarpleKit suite (no regressions)**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: PASS — all suites green (104 prior + the new tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/MarpleKit/HTTPVaultClient.swift Tests/MarpleKitTests/HTTPVaultClientTests.swift
git commit -m "$(cat <<'EOF'
feat(native): HTTPVaultClient create + trash endpoints

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `AppModel` trash state + actions (executable)

**Files:**
- Modify: `Sources/Marple/AppModel.swift`

Additive only (no `Pane` change yet), so the executable keeps compiling. These methods are wired into the UI in Task 6.

- [ ] **Step 1: Add the trash state property**

In `Sources/Marple/AppModel.swift`, after the `private(set) var annotationIndex` line (the index-derived caches block), add:

```swift
    // Trash list (loaded lazily; sidebar badge reads .count).
    private(set) var trashItems: [TrashItem] = []
```

- [ ] **Step 2: Load trash at boot**

In `loadIndex()`, add `await loadTrash()` immediately after `recomputeVisible()` (inside the `do` block, before the `print`):

```swift
            rebuildIndexDerived()
            recomputeVisible()
            await loadTrash()
            print("[marple] index loaded: \(entries.count) entries")
```

- [ ] **Step 3: Add the trash actions**

In `Sources/Marple/AppModel.swift`, add a new section before the `// MARK: metadata write-back` section:

```swift
    // MARK: trash

    func loadTrash() async {
        do { trashItems = try await client.listTrash() }
        catch { print("[marple] listTrash FAILED: \(error)") }
    }

    /// Soft-delete `path`: backend moves it to .trash, then optimistically drop
    /// it from the in-memory index. If the active tab shows it, clear the doc.
    func moveToTrash(_ path: String) async {
        writeError = nil
        do {
            _ = try await client.moveToTrash(path: path)
            entries.removeAll { $0.path == path }
            if openPath == path {
                workspace.navigateActive(to: NavLocation(pane: pane, openPath: nil))
                await loadDoc(nil)
            }
            rebuildIndexDerived(); recomputeVisible()
            await loadTrash()
            print("[marple] trashed \(path)")
        } catch {
            writeError = "\(error)"
            print("[marple] trash FAILED \(path): \(error)")
        }
    }

    /// Restore re-adds a file we can't cheaply describe → reload the whole index
    /// (rare action; loadIndex also refreshes the trash list).
    func restoreTrash(_ name: String) async {
        writeError = nil
        do {
            _ = try await client.restoreTrash(name: name)
            await loadIndex()
            print("[marple] restored \(name)")
        } catch {
            writeError = "\(error)"
            print("[marple] restore FAILED \(name): \(error)")
        }
    }

    func purgeTrash(_ name: String) async {
        writeError = nil
        do {
            try await client.purgeTrash(name: name)
            trashItems.removeAll { $0.name == name }
            print("[marple] purged \(name)")
        } catch {
            writeError = "\(error)"
            print("[marple] purge FAILED \(name): \(error)")
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/Marple/AppModel.swift
git commit -m "$(cat <<'EOF'
feat(native): AppModel trash state + move/restore/purge actions

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `Pane.trash` + 回收站 view + sidebar/routing (MarpleKit + executable)

**Files:**
- Modify: `Sources/MarpleKit/Browse.swift`
- Test: `Tests/MarpleKitTests/BrowseTests.swift`
- Create: `Sources/Marple/TrashView.swift`
- Modify: `Sources/Marple/SidebarView.swift`, `Sources/Marple/RootView.swift`, `Sources/Marple/EntryListView.swift`, `Sources/Marple/AppModel.swift`

Adding `Pane.trash` forces every `switch pane` to handle the new case; this task updates all of them and lands the view, so the package goes green in one cohesive slice (no throwaway).

- [ ] **Step 1: Write the failing MarpleKit test**

Append to `Tests/MarpleKitTests/BrowseTests.swift` (inside the existing suite, before its closing brace):

```swift
    @Test func testTrashPaneHasNoEntries() {
        let e = Entry(path: "vault/a.md", type: .note, title: nil, author: nil, year: nil,
                      ratingScore: 0, themes: [], preview: "", hasPDF: false)
        #expect(entriesForPane(.trash, in: [e]).isEmpty)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter BrowseTests`
Expected: FAIL — compile error "type 'Pane' has no member 'trash'".

- [ ] **Step 3: Add the `Pane.trash` case**

In `Sources/MarpleKit/Browse.swift`, add the case and its handling:

```swift
public enum Pane: Hashable, Sendable {
    case type(EntryType)
    case themesIndex
    case theme(String)
    case trash
}

/// Base subset for a pane, before filter/sort. `.themesIndex` and `.trash` are
/// not list-of-entry views.
public func entriesForPane(_ pane: Pane, in entries: [Entry]) -> [Entry] {
    switch pane {
    case .type(let t):     return entries.filter { $0.type == t }
    case .theme(let name): return entries.filter { $0.themes.contains(name) }
    case .themesIndex:     return []
    case .trash:           return []
    }
}
```

- [ ] **Step 4: Run the MarpleKit test to verify it passes**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter BrowseTests`
Expected: PASS.

- [ ] **Step 5: Handle `.trash` in the executable's exhaustive switches**

In `Sources/Marple/AppModel.swift`, in `tabTitle(_:)`, add the case to the inner `switch loc.pane`:

```swift
        switch loc.pane {
        case .type(let t):     return t.label
        case .theme(let name): return "#\(name)"
        case .themesIndex:     return "主题"
        case .trash:           return "回收站"
        }
```

Also in `AppModel.select(pane:)`, refresh the trash list when entering it. Replace the body of `select(pane:)` with:

```swift
    func select(pane newPane: Pane) {
        workspace.navigateActive(to: NavLocation(pane: newPane, openPath: openPath))
        searchText = ""; searchHits = []
        recomputeVisible()
        if case .trash = newPane { Task { await loadTrash() } }
        print("[marple] pane -> \(newPane)")
    }
```

In `Sources/Marple/EntryListView.swift`, add the case to the `title` switch:

```swift
    private var title: String {
        switch model.pane {
        case .type(let t):   return "\(t.label) (\(model.visibleEntries.count))"
        case .theme(let n):  return "主题: \(n) (\(model.visibleEntries.count))"
        case .themesIndex:   return "主题"
        case .trash:         return "回收站"
        }
    }
```

- [ ] **Step 6: Create `TrashView`**

Create `Sources/Marple/TrashView.swift`:

```swift
import SwiftUI
import MarpleKit

struct TrashView: View {
    @Bindable var model: AppModel
    @State private var pendingPurge: TrashItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.trashItems.isEmpty {
                ContentUnavailableView("回收站为空", systemImage: "trash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.trashItems) { item in
                    TrashRow(item: item)
                        .contextMenu {
                            Button("恢复") { Task { await model.restoreTrash(item.name) } }
                            Divider()
                            Button("彻底删除", role: .destructive) { pendingPurge = item }
                        }
                }
            }
        }
        .navigationTitle("回收站")
        .confirmationDialog(
            "彻底删除这个文件？此操作不可撤销。",
            isPresented: Binding(get: { pendingPurge != nil },
                                 set: { if !$0 { pendingPurge = nil } }),
            presenting: pendingPurge
        ) { item in
            Button("彻底删除", role: .destructive) { Task { await model.purgeTrash(item.name) } }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Text("\(model.trashItems.count) 项").foregroundStyle(.secondary)
            Spacer()
            Button { Task { await model.loadTrash() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新")
        }
        .padding(8)
    }
}

private struct TrashRow: View {
    let item: TrashItem
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.originalBase ?? item.name)
            HStack(spacing: 8) {
                if let ts = item.ts { Text(ts) }
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 7: Route `.trash` in `RootView`**

In `Sources/Marple/RootView.swift`, replace the `content:` `Group` (the `if case .themesIndex … else …` block) with a switch:

```swift
            } content: {
                Group {
                    switch model.pane {
                    case .themesIndex: ThemesView(model: model)
                    case .trash:       TrashView(model: model)
                    default:           EntryListView(model: model)
                    }
                }
                .frame(minWidth: 320)
            } detail: {
```

- [ ] **Step 8: Add the 回收站 sidebar row + 移到回收站 context menu**

In `Sources/Marple/SidebarView.swift`, add the 回收站 row to the "视图" section, after the 主题 label:

```swift
            Section("视图") {
                Label {
                    HStack {
                        Text("主题")
                        Spacer()
                        Text("\(model.themeIndex.count)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: { Image(systemName: "tag") }
                .tag(Pane.themesIndex)

                Label {
                    HStack {
                        Text("回收站")
                        Spacer()
                        Text("\(model.trashItems.count)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: { Image(systemName: "trash") }
                .tag(Pane.trash)
            }
```

In `Sources/Marple/EntryListView.swift`, extend the row context menu with a soft-delete (the 新建批注 item is added in Task 8):

```swift
                EntryRow(entry: entry)
                    .contextMenu {
                        Button("在新标签页打开") { Task { await model.openInNewTab(entry.path) } }
                        Divider()
                        Button("移到回收站", role: .destructive) {
                            Task { await model.moveToTrash(entry.path) }
                        }
                    }
```

- [ ] **Step 9: Build the whole package**

Run: `swift build`
Expected: `Build complete!` — all `switch pane` sites handled, `TrashView` compiles.

- [ ] **Step 10: Commit**

```bash
git add Sources/MarpleKit/Browse.swift Tests/MarpleKitTests/BrowseTests.swift Sources/Marple/TrashView.swift Sources/Marple/SidebarView.swift Sources/Marple/RootView.swift Sources/Marple/EntryListView.swift Sources/Marple/AppModel.swift
git commit -m "$(cat <<'EOF'
feat(native): 回收站 pane + view + soft-delete from list

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `AppModel` note-creation actions (executable)

**Files:**
- Modify: `Sources/Marple/AppModel.swift`

Create → optimistically append a known `Entry` → reveal in the reader → hand off to the external editor.

- [ ] **Step 1: Add the creation actions**

In `Sources/Marple/AppModel.swift`, add a new section after the `// MARK: trash` section:

```swift
    // MARK: note creation

    func newIdeaNote() async {
        let draft = NoteBuilder.ideaNote()
        await createAndReveal(draft, entry: ideaEntry(from: draft))
    }

    func newAnnotation(for entry: Entry) async {
        let draft = NoteBuilder.annotation(target: entry)
        await createAndReveal(draft, entry: annotationEntry(from: draft, target: entry))
    }

    func newAnnotationForOpenDoc() async {
        guard let e = openEntry else { return }
        await newAnnotation(for: e)
    }

    /// POST the draft, optimistically add its Entry, reveal it, then open it in
    /// the external editor (this is a reader — the empty note is edited outside).
    private func createAndReveal(_ draft: NoteDraft, entry: Entry) async {
        writeError = nil
        do {
            try await client.createNote(path: draft.path, text: draft.text)
            entries.append(entry)
            rebuildIndexDerived(); recomputeVisible()
            await open(draft.path)
            await openExternally()
            print("[marple] created \(draft.path)")
        } catch {
            writeError = "\(error)"
            print("[marple] create FAILED \(draft.path): \(error)")
        }
    }

    private func ideaEntry(from draft: NoteDraft) -> Entry {
        Entry(path: draft.path, type: .note, title: draft.title, author: nil, year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }

    private func annotationEntry(from draft: NoteDraft, target: Entry) -> Entry {
        Entry(path: draft.path, type: .note, title: draft.title, author: nil, year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false, annotates: target.path)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Marple/AppModel.swift
git commit -m "$(cat <<'EOF'
feat(native): AppModel new idea note + annotation actions

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Creation UI surfaces (executable)

**Files:**
- Modify: `Sources/Marple/SidebarView.swift`, `Sources/Marple/DocView.swift`, `Sources/Marple/EntryListView.swift`, `Sources/Marple/TabCommands.swift`

Wires the Task 7 actions to: a sidebar 新建笔记 button, a toolbar `+` and ⌘N (idea note), and 新建批注 in the list context menu + DocView toolbar.

- [ ] **Step 1: Sidebar 新建笔记 button**

In `Sources/Marple/SidebarView.swift`, attach a bottom button to the `List` (add the modifier after `.navigationTitle("Marple")`):

```swift
        .navigationTitle("Marple")
        .safeAreaInset(edge: .bottom) {
            Button { Task { await model.newIdeaNote() } } label: {
                Label("新建笔记", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
```

- [ ] **Step 2: DocView 新建批注 + `+` toolbar items**

In `Sources/Marple/DocView.swift`, replace the `.toolbar { … }` block with one that adds the `+` (idea note) and 新建批注 (open-doc annotation) items:

```swift
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { Task { await model.newIdeaNote() } } label: {
                    Image(systemName: "plus")
                }
                .help("新建笔记")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("新建批注") { Task { await model.newAnnotationForOpenDoc() } }
                    .disabled(model.openEntry == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("用外部编辑器打开") { Task { await model.openExternally() } }
                    .disabled(model.openPath == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { inspectorShown.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
            }
        }
```

- [ ] **Step 3: 新建批注 in the list context menu**

In `Sources/Marple/EntryListView.swift`, add the 新建批注 button to the row context menu (final form):

```swift
                EntryRow(entry: entry)
                    .contextMenu {
                        Button("在新标签页打开") { Task { await model.openInNewTab(entry.path) } }
                        Button("新建批注") { Task { await model.newAnnotation(for: entry) } }
                        Divider()
                        Button("移到回收站", role: .destructive) {
                            Task { await model.moveToTrash(entry.path) }
                        }
                    }
```

- [ ] **Step 4: ⌘N 新建笔记 command**

In `Sources/Marple/TabCommands.swift`, add a new-item command group inside `body`, before the `CommandGroup(replacing: .saveItem)` block:

```swift
        CommandGroup(replacing: .newItem) {
            Button("新建笔记") { run { await $0.newIdeaNote() } }
                .keyboardShortcut("n", modifiers: .command)
        }

```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Marple/SidebarView.swift Sources/Marple/DocView.swift Sources/Marple/EntryListView.swift Sources/Marple/TabCommands.swift
git commit -m "$(cat <<'EOF'
feat(native): new note/annotation UI (sidebar, toolbar, ⌘N, menus)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Full verification + GUI validation + handoff

**Files:**
- Create: `docs/superpowers/2026-05-23-marple-native-p4-handoff.md`

- [ ] **Step 1: Full build + full test run**

Run (from `apple/`):
```
swift build
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```
Expected: `Build complete!` and all swift-testing suites green (104 prior + ~16 new ≈ 120 tests). If any fail, fix before proceeding — do not claim completion on red.

- [ ] **Step 2: Launch the app for GUI validation**

Run (from `apple/`, captures live logs):
```
swift run Marple > /tmp/marple-app.log 2>&1 &
```
Then exercise this checklist against the real vault (the user performs / confirms this — see the user's "batch then test" preference: this is the single human checkpoint):

- **新建笔记 (idea note)** via (a) sidebar button, (b) toolbar `+`, (c) ⌘N → each creates a `vault/notes/<date>-idea-<stamp>.md`, the note appears in 笔记 list + opens in the reader **and** launches the external editor.
- **新建批注 (annotation)** via (a) list context menu on an entry, (b) DocView toolbar while reading a doc → creates `…-note-<stamp>.md` with `annotates:` set to the target path; reveals + opens externally.
- **移到回收站** from a list row context menu → the row disappears from the list; the 回收站 sidebar badge increments; if that doc was open, the reader clears.
- **回收站 view** → lists trashed items; **恢复** returns the file to its type list (full index reload); **彻底删除** shows a confirmation, then removes the item.
- Confirm no panics in `/tmp/marple-app.log` (the pre-existing NSTableView reentrancy warning is expected/benign).

- [ ] **Step 3: Write the handoff doc**

Create `docs/superpowers/2026-05-23-marple-native-p4-handoff.md` recording: what shipped (the 5 VaultClient methods, NoteBuilder, TrashItem, Pane.trash, AppModel actions, TrashView + UI surfaces), the freshness decisions (optimistic create/trash, restore reloads, watcher-index-refresh still deferred), test count, GUI-validation status, and that P2–P4 remain committed-not-pushed on `main`. Mirror the structure of `docs/superpowers/2026-05-23-marple-native-p3b-handoff.md`.

- [ ] **Step 4: Commit the handoff**

```bash
git add docs/superpowers/2026-05-23-marple-native-p4-handoff.md
git commit -m "$(cat <<'EOF'
docs(p4): file management work log (GUI-validated)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review notes (for the implementer)

- **Spec coverage:** §3 VaultClient → Tasks 3–4; §4.1 NoteBuilder → Task 2; §4.2 Pane.trash → Task 6; §3 TrashItem → Task 1; §5 AppModel (create/trash/restore/purge + optimistic, restore-reloads) → Tasks 5, 7; §6 UI (sidebar row + 新建 button, toolbar+⌘N, list context menu, DocView button, TrashView, RootView routing) → Tasks 6, 8; §7 error handling → folded into each action (writeError + no optimistic change on failure); §8 testing → Tasks 1–4 unit, Task 9 GUI.
- **Type consistency:** `moveToTrash`/`restoreTrash` return `String`; `loadTrash`/`purgeTrash` return `Void`. `TrashStore` exposes `moved`/`restored`/`purged`/`items`. `NoteDraft` fields are `path`/`text`/`title`. These names are used identically across tasks.
- **Known intentional deviations from a literal reading of the spec:** the note `title` uses `FrontmatterPatch.yamlScalar` (quote-only-when-needed) rather than always-quoting like the web's `JSON.stringify`; output is equivalent valid YAML and the indexer reads it the same. Background tabs/history pointing at a trashed doc are not pruned (only the active tab is cleared) — accepted in spec §10.
