# marple-native P2 (Browse) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the P1 single-list reader into a typed browser: a 6-category sidebar with live counts, a per-type entry list with multi-clause sort + flat filters, lexical search via the existing backend, and a 主题 cross-cut view.

**Architecture:** All new browse logic (sort, filter, theme index, search DTOs) lands in `MarpleKit` as pure, swift-testing-covered functions — mirroring the web app's `list-sort.ts` / `list-filter.ts` / `search.ts`. The SwiftUI app gains a three-column `NavigationSplitView` (types → entry list → doc); the middle column composes the pure pipeline. Search reuses the sidecar's `GET /api/search` (fast/lexical mode) through a new `VaultClient.search` method — no transport leaks past the protocol boundary (B2→B1 discipline from the design spec §4).

**Tech Stack:** Swift 6 / SwiftUI (macOS 14), `MarpleKit` SPM lib, swift-testing (`import Testing`), existing Rust `reader-api` sidecar.

**Spec:** `docs/superpowers/specs/2026-05-23-marple-native-reader-design.md` §11 P2 (Browse) + §5/§8.
**Predecessor:** `docs/superpowers/2026-05-23-marple-native-p1-handoff.md`.

---

## Conventions (carried from P1 — MUST follow)

- **Work directly on `main`.** No feature branch / worktree (user authorized).
- **Only stage files you authored under `apple/` and `docs/`.** The user has
  unrelated working-tree edits to `index.html`, `src/components/DocView.tsx`,
  `src/components/Sidebar.tsx`, `src-tauri/tauri.conf.json` — never stage,
  commit, or revert those. Never break the web build.
- **Build:** `cd apple && swift build`
- **Test (CLT-only — no Xcode, so swift-testing not XCTest):**
  `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
- **Run + capture logs (controller can't see the GUI):**
  `cd apple && swift run Marple > /tmp/marple-app.log 2>&1` then have the user
  drive the UI while you tail the log. Stop a run:
  `pkill -f "debug/Marple"; pkill -f "release/reader-api"`.

## Wire-shape facts (verified against the running backend)

- `GET /api/index` → `{ "items": [Entry], "generatedFrom": "..." }`. Entry JSON
  carries fields the Swift `Entry` does not yet decode: `mtime` (epoch ms,
  nullable), `added` (epoch ms), `source`, `book`, `topic`, `doi`.
- `GET /api/search?q=&mode=fast&entry_type=&min_rating=&theme=&limit=` →
  `{ "items": [ { "entry": Entry, "score": Number, "snippet": String|null, "source": String } ] }`.
  `mode=fast` is lexical/metadata only (P2 scope; balanced/deep are P5).
- There is **no** themes endpoint. The 主题 index is computed Swift-side from
  `entries[].themes`.
- The 6 modeled types and their labels (mirror web `TYPES` order):
  `paper-analysis 论文 · book-overview 图书 · author-profile 作者 · topic-synthesis 主题 · chapter-summary 章节 · note 笔记`.

## File Structure

**MarpleKit (pure logic — TDD):**
- Modify `apple/Sources/MarpleKit/Entry.swift` — decode `mtime/added/source/book/topic/doi`; add `EntryType.modeled` + `EntryType.label`.
- Create `apple/Sources/MarpleKit/ListSort.swift` — `SortField`, `SortDir`, `SortClause`, `sortEntries(_:by:)`.
- Create `apple/Sources/MarpleKit/ListFilter.swift` — `FilterField/Op/Match`, `FilterClause`, `applyFilters(_:_:match:now:)`, `clauseLabel`.
- Create `apple/Sources/MarpleKit/ThemeIndex.swift` — `themeCounts(_:) -> [(theme: String, count: Int)]`.
- Create `apple/Sources/MarpleKit/Browse.swift` — `Pane` enum + `entriesForPane(_:in:)` (the base subset before filter/sort).
- Modify `apple/Sources/MarpleKit/VaultClient.swift` — add `SearchQuery`, `SearchHit`, `search(_:)`; update `StubVaultClient`.
- Modify `apple/Sources/MarpleKit/HTTPVaultClient.swift` — implement `search(_:)` → `/api/search`.

**Marple app (SwiftUI — build + manual GUI validation):**
- Modify `apple/Sources/Marple/AppModel.swift` — generalize from `papers` to `pane`, `counts`, `themeIndex`, `sortClauses`, `filterClauses`, `filterMatch`, `searchText`/`searchHits`, computed `visibleEntries`.
- Modify `apple/Sources/Marple/SidebarView.swift` — typed sections (物件 6 types + 视图 主题) with counts, selection bound to `pane`.
- Create `apple/Sources/Marple/EntryListView.swift` — middle column: header (search + sort + filter) over a `List` of `EntryRow`.
- Create `apple/Sources/Marple/EntryRow.swift` — type-aware row.
- Create `apple/Sources/Marple/ThemesView.swift` — 主题 index grid; tap a theme → `pane = .theme(name)`.
- Modify `apple/Sources/Marple/MarpleApp.swift` — three-column `NavigationSplitView`.

**Tests:**
- Modify `apple/Tests/MarpleKitTests/EntryDecodeTests.swift`
- Create `apple/Tests/MarpleKitTests/ListSortTests.swift`
- Create `apple/Tests/MarpleKitTests/ListFilterTests.swift`
- Create `apple/Tests/MarpleKitTests/ThemeIndexTests.swift`
- Create `apple/Tests/MarpleKitTests/BrowseTests.swift`
- Modify `apple/Tests/MarpleKitTests/HTTPVaultClientTests.swift`
- Modify `apple/Tests/MarpleKitTests/VaultClientStubTests.swift`

---

### Task 1: Extend `Entry` decoding (mtime / added / source / book / topic / doi)

**Files:**
- Modify: `apple/Sources/MarpleKit/Entry.swift`
- Test: `apple/Tests/MarpleKitTests/EntryDecodeTests.swift`

- [ ] **Step 1: Add the failing test**

Append to `EntryDecodeTests.swift` inside the `@Suite struct EntryDecodeTests`:

```swift
    @Test func testDecodesBrowseFieldsForSortAndFilter() throws {
        let entries = try decode("""
        [{"path":"vault/p/a.md","type":"paper-analysis","title":"A","rating_score":0,
          "preview":"","mtime":1700000000000,"added":1690000000000,
          "source":"JSTOR","book":"Some Book","topic":"econ","doi":"10.1/x"}]
        """)
        let e = entries[0]
        #expect(e.mtime == 1700000000000)
        #expect(e.added == 1690000000000)
        #expect(e.source == "JSTOR")
        #expect(e.book == "Some Book")
        #expect(e.topic == "econ")
        #expect(e.doi == "10.1/x")
    }

    @Test func testBrowseFieldsTolerateAbsence() throws {
        let entries = try decode("""
        [{"path":"vault/n/b.md","type":"note","preview":"","rating_score":0}]
        """)
        let e = entries[0]
        #expect(e.mtime == nil)
        #expect(e.added == nil)
        #expect(e.source == nil)
    }
```

- [ ] **Step 2: Run the test, verify it fails to compile (no such members)**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter EntryDecodeTests`
Expected: build error — `value of type 'Entry' has no member 'mtime'`.

- [ ] **Step 3: Add the stored properties + decode**

In `Entry.swift`, add to the `Entry` struct's stored properties (after `hasPDF`):

```swift
    public let mtime: Double?
    public let added: Double?
    public let source: String?
    public let book: String?
    public let topic: String?
    public let doi: String?
```

Add to `CodingKeys`:

```swift
        case mtime, added, source, book, topic, doi
```

In `init(from:)`, before the closing `}`, add:

```swift
        mtime = (try? c.decodeIfPresent(Double.self, forKey: .mtime)) ?? nil
        added = (try? c.decodeIfPresent(Double.self, forKey: .added)) ?? nil
        source = try? c.decodeIfPresent(String.self, forKey: .source) ?? nil
        book = try? c.decodeIfPresent(String.self, forKey: .book) ?? nil
        topic = try? c.decodeIfPresent(String.self, forKey: .topic) ?? nil
        doi = try? c.decodeIfPresent(String.self, forKey: .doi) ?? nil
```

In the memberwise `init(path:...)`, add matching parameters (with defaults so
existing call sites in tests keep compiling) at the end of the parameter list:

```swift
                mtime: Double? = nil, added: Double? = nil, source: String? = nil,
                book: String? = nil, topic: String? = nil, doi: String? = nil,
```

and assignments in the body:

```swift
        self.mtime = mtime
        self.added = added
        self.source = source
        self.book = book
        self.topic = topic
        self.doi = doi
```

Note: place the new params **after** `hasPDF` but the trailing-default style means
existing positional callers (which pass through `hasPDF`) still compile. If any
caller used a trailing closure-free positional call past `hasPDF`, none exists today.

- [ ] **Step 4: Run the test, verify it passes**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter EntryDecodeTests`
Expected: PASS (all EntryDecodeTests green).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Entry.swift apple/Tests/MarpleKitTests/EntryDecodeTests.swift
git commit -m "feat(native): decode browse fields (mtime/added/source/book/topic/doi)"
```

---

### Task 2: `EntryType` ordering + labels

**Files:**
- Modify: `apple/Sources/MarpleKit/Entry.swift`
- Test: `apple/Tests/MarpleKitTests/EntryDecodeTests.swift`

- [ ] **Step 1: Add the failing test**

Append inside `EntryDecodeTests`:

```swift
    @Test func testModeledTypesOrderAndLabels() {
        #expect(EntryType.modeled == [.paperAnalysis, .bookOverview, .authorProfile,
                                      .topicSynthesis, .chapterSummary, .note])
        #expect(EntryType.paperAnalysis.label == "论文")
        #expect(EntryType.note.label == "笔记")
        #expect(EntryType.other("topic-reading-list").label == "topic-reading-list")
    }
```

- [ ] **Step 2: Run, verify fails**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter EntryDecodeTests`
Expected: build error — `type 'EntryType' has no member 'modeled'`.

- [ ] **Step 3: Implement**

In `Entry.swift`, after the `EntryType` enum (outside it), add:

```swift
public extension EntryType {
    /// The six modeled types in the canonical sidebar order (mirrors web TYPES).
    static let modeled: [EntryType] = [
        .paperAnalysis, .bookOverview, .authorProfile,
        .topicSynthesis, .chapterSummary, .note,
    ]

    var label: String {
        switch self {
        case .paperAnalysis:  return "论文"
        case .bookOverview:   return "图书"
        case .authorProfile:  return "作者"
        case .topicSynthesis: return "主题"
        case .chapterSummary: return "章节"
        case .note:           return "笔记"
        case .other(let raw): return raw
        }
    }
}
```

Make `EntryType` conform to `Hashable` so it can drive a `List` selection later —
change the declaration line to:

```swift
public enum EntryType: RawRepresentable, Codable, Sendable, Equatable, Hashable {
```

- [ ] **Step 4: Run, verify passes**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter EntryDecodeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Entry.swift apple/Tests/MarpleKitTests/EntryDecodeTests.swift
git commit -m "feat(native): EntryType modeled order + 中文 labels"
```

---

### Task 3: Port multi-clause sort (`ListSort.swift`)

**Files:**
- Create: `apple/Sources/MarpleKit/ListSort.swift`
- Test: `apple/Tests/MarpleKitTests/ListSortTests.swift`

Port `src/list-sort.ts` `sortEntriesMulti` semantics: empty clause list → input
unchanged; empties always sort last regardless of direction; stable (ties keep
input order). Fields: `rating` (ratingScore, 0 == unrated == empty), `year`
(numeric), `added`, `updated` (mtime), `title`, `author` (locale-aware).

- [ ] **Step 1: Write the failing test**

Create `ListSortTests.swift`:

```swift
import Testing
@testable import MarpleKit

@Suite struct ListSortTests {
    func e(_ path: String, title: String? = nil, year: String? = nil,
           rating: Double = 0, mtime: Double? = nil, added: Double? = nil) -> Entry {
        Entry(path: path, type: .paperAnalysis, title: title, author: nil, year: year,
              ratingScore: rating, themes: [], preview: "", hasPDF: false,
              mtime: mtime, added: added)
    }

    @Test func testEmptyClausesPreserveOrder() {
        let list = [e("a"), e("b"), e("c")]
        #expect(sortEntries(list, by: []).map(\.path) == ["a", "b", "c"])
    }

    @Test func testRatingDescEmptiesLast() {
        let list = [e("a", rating: 0), e("b", rating: 4), e("c", rating: 2)]
        let out = sortEntries(list, by: [SortClause(field: .rating, dir: .desc)])
        #expect(out.map(\.path) == ["b", "c", "a"])
    }

    @Test func testRatingAscStillFloatsEmptiesLast() {
        let list = [e("a", rating: 0), e("b", rating: 4), e("c", rating: 2)]
        let out = sortEntries(list, by: [SortClause(field: .rating, dir: .asc)])
        #expect(out.map(\.path) == ["c", "b", "a"])
    }

    @Test func testMultiClauseTieBreak() {
        // same year, break by rating desc
        let list = [e("a", year: "2020", rating: 1),
                    e("b", year: "2020", rating: 3),
                    e("c", year: "2019", rating: 5)]
        let out = sortEntries(list, by: [SortClause(field: .year, dir: .desc),
                                         SortClause(field: .rating, dir: .desc)])
        #expect(out.map(\.path) == ["b", "a", "c"])
    }

    @Test func testTitleLocaleAsc() {
        let list = [e("a", title: "Beta"), e("b", title: "alpha"), e("c", title: nil)]
        let out = sortEntries(list, by: [SortClause(field: .title, dir: .asc)])
        #expect(out.map(\.path) == ["b", "a", "c"])  // nil title last
    }
}
```

- [ ] **Step 2: Run, verify fails**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter ListSortTests`
Expected: build error — `cannot find 'sortEntries'`.

- [ ] **Step 3: Implement `ListSort.swift`**

```swift
import Foundation

public enum SortField: String, Sendable, CaseIterable, Hashable {
    case rating, year, added, updated, title, author

    public var label: String {
        switch self {
        case .rating:  return "评分"
        case .year:    return "年份"
        case .added:   return "入库时间"
        case .updated: return "更新时间"
        case .title:   return "标题"
        case .author:  return "作者"
        }
    }

    /// Sensible default direction when the user picks this field.
    public var defaultDir: SortDir { (self == .title || self == .author) ? .asc : .desc }
}

public enum SortDir: String, Sendable, Hashable { case asc, desc }

public struct SortClause: Sendable, Equatable, Hashable {
    public var field: SortField
    public var dir: SortDir
    public init(field: SortField, dir: SortDir) { self.field = field; self.dir = dir }
}

private func textCmp(_ a: String?, _ b: String?, _ dir: SortDir) -> Int {
    let ea = (a ?? "").isEmpty, eb = (b ?? "").isEmpty
    if ea && eb { return 0 }
    if ea { return 1 }            // empties last
    if eb { return -1 }
    let c = a!.compare(b!, options: [.caseInsensitive], range: nil, locale: Locale(identifier: "zh_Hans_CN"))
    let r = c == .orderedAscending ? -1 : (c == .orderedDescending ? 1 : 0)
    return dir == .asc ? r : -r
}

private func numCmp(_ a: Double?, _ b: Double?, _ dir: SortDir) -> Int {
    let ea = a == nil, eb = b == nil
    if ea && eb { return 0 }
    if ea { return 1 }            // empties last
    if eb { return -1 }
    let r = a! < b! ? -1 : (a! > b! ? 1 : 0)
    return dir == .asc ? r : -r
}

private func toNum(_ s: String?) -> Double? {
    guard let s, !s.isEmpty else { return nil }
    return Double(s)
}

private func comparator(_ field: SortField, _ dir: SortDir) -> (Entry, Entry) -> Int {
    switch field {
    case .title:   return { textCmp($0.title, $1.title, dir) }
    case .author:  return { textCmp($0.author, $1.author, dir) }
    case .year:    return { numCmp(toNum($0.year), toNum($1.year), dir) }
    // ratingScore 0 means "unrated" → treat as empty so it sorts last either way.
    case .rating:  return { numCmp($0.ratingScore == 0 ? nil : $0.ratingScore,
                                   $1.ratingScore == 0 ? nil : $1.ratingScore, dir) }
    case .updated: return { numCmp($0.mtime, $1.mtime, dir) }
    case .added:   return { numCmp($0.added, $1.added, dir) }
    }
}

/// Multi-level stable sort. Empty clause list returns the input unchanged.
/// Ties fall through to the next clause, then to original index.
public func sortEntries(_ list: [Entry], by clauses: [SortClause]) -> [Entry] {
    guard !clauses.isEmpty else { return list }
    let cmps = clauses.map { comparator($0.field, $0.dir) }
    return list.enumerated().sorted { lhs, rhs in
        for cmp in cmps {
            let r = cmp(lhs.element, rhs.element)
            if r != 0 { return r < 0 }
        }
        return lhs.offset < rhs.offset
    }.map(\.element)
}
```

- [ ] **Step 4: Run, verify passes**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter ListSortTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/ListSort.swift apple/Tests/MarpleKitTests/ListSortTests.swift
git commit -m "feat(native): port multi-clause list sort"
```

---

### Task 4: Port flat filters (`ListFilter.swift`)

**Files:**
- Create: `apple/Sources/MarpleKit/ListFilter.swift`
- Test: `apple/Tests/MarpleKitTests/ListFilterTests.swift`

Port `src/list-filter.ts`: flat `{field, op, value}` clauses combined by `all`
(AND) / `any` (OR); incomplete clauses ignored. Fields: `rating` (gte/eq/lte),
`year` (gte/eq/lte), `author` (contains), `theme` (is/contains), `source`
(contains/is), `haspdf` (yes), `added` (within N days).

- [ ] **Step 1: Write the failing test**

Create `ListFilterTests.swift`:

```swift
import Foundation
import Testing
@testable import MarpleKit

@Suite struct ListFilterTests {
    func e(_ path: String, author: String? = nil, year: String? = nil, rating: Double = 0,
           themes: [String] = [], source: String? = nil, hasPDF: Bool = false,
           added: Double? = nil) -> Entry {
        Entry(path: path, type: .paperAnalysis, title: nil, author: author, year: year,
              ratingScore: rating, themes: themes, preview: "", hasPDF: hasPDF,
              mtime: nil, added: added, source: source)
    }

    @Test func testNoClausesReturnsAll() {
        let list = [e("a"), e("b")]
        #expect(applyFilters(list, [], match: .all).count == 2)
    }

    @Test func testRatingGteAndHasPdfAll() {
        let list = [e("a", rating: 4, hasPDF: true), e("b", rating: 4, hasPDF: false),
                    e("c", rating: 1, hasPDF: true)]
        let cs = [FilterClause(field: .rating, op: .gte, value: "3"),
                  FilterClause(field: .haspdf, op: .yes, value: "")]
        #expect(applyFilters(list, cs, match: .all).map(\.path) == ["a"])
    }

    @Test func testAnyMode() {
        let list = [e("a", rating: 4), e("b", year: "2020"), e("c")]
        let cs = [FilterClause(field: .rating, op: .gte, value: "3"),
                  FilterClause(field: .year, op: .gte, value: "2000")]
        #expect(Set(applyFilters(list, cs, match: .any).map(\.path)) == ["a", "b"])
    }

    @Test func testIncompleteClauseIgnored() {
        let list = [e("a", rating: 1)]
        let cs = [FilterClause(field: .rating, op: .gte, value: "")]  // no value
        #expect(applyFilters(list, cs, match: .all).count == 1)
    }

    @Test func testThemeIsVsContains() {
        let list = [e("a", themes: ["macro econ"]), e("b", themes: ["econ"])]
        #expect(applyFilters(list, [FilterClause(field: .theme, op: .is, value: "econ")],
                             match: .all).map(\.path) == ["b"])
        #expect(Set(applyFilters(list, [FilterClause(field: .theme, op: .contains, value: "econ")],
                                 match: .all).map(\.path)) == ["a", "b"])
    }

    @Test func testAddedWithinDays() {
        let now = Date(timeIntervalSince1970: 1_000_000) // fixed
        let recent = (now.timeIntervalSince1970 - 86400) * 1000   // 1 day ago, ms
        let old = (now.timeIntervalSince1970 - 10 * 86400) * 1000 // 10 days ago
        let list = [e("a", added: recent), e("b", added: old)]
        let cs = [FilterClause(field: .added, op: .within, value: "3")]
        #expect(applyFilters(list, cs, match: .all, now: now).map(\.path) == ["a"])
    }
}
```

- [ ] **Step 2: Run, verify fails**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter ListFilterTests`
Expected: build error — `cannot find 'applyFilters'`.

- [ ] **Step 3: Implement `ListFilter.swift`**

```swift
import Foundation

public enum FilterField: String, Sendable, CaseIterable, Hashable {
    case rating, year, author, theme, source, haspdf, added

    public var label: String {
        switch self {
        case .rating: return "评分"
        case .year:   return "年份"
        case .author: return "作者"
        case .theme:  return "主题"
        case .source: return "来源"
        case .haspdf: return "有 PDF"
        case .added:  return "入库"
        }
    }

    /// Value input kind: text, number, or none (haspdf is a pure predicate).
    public var input: FilterInput {
        switch self {
        case .rating, .year, .added: return .number
        case .author, .theme, .source: return .text
        case .haspdf: return .none
        }
    }
}

public enum FilterInput: Sendable { case number, text, none }
public enum FilterOp: String, Sendable, Hashable { case gte, lte, eq, contains, is_ = "is", yes, within }
public enum FilterMatch: String, Sendable, Hashable { case all, any }

public struct FilterClause: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public var field: FilterField
    public var op: FilterOp
    public var value: String
    public init(id: String = UUID().uuidString, field: FilterField, op: FilterOp, value: String) {
        self.id = id; self.field = field; self.op = op; self.value = value
    }
}

private func toNum(_ s: String?) -> Double? {
    guard let s, !s.isEmpty else { return nil }
    return Double(s)
}

/// True when a clause has enough input to actually filter.
public func clauseReady(_ c: FilterClause) -> Bool {
    switch c.field.input {
    case .none:   return true
    case .number: return toNum(c.value.trimmingCharacters(in: .whitespaces)) != nil
    case .text:   return !c.value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

private func test(_ e: Entry, _ c: FilterClause, now: Date) -> Bool {
    switch c.field {
    case .rating:
        guard let want = toNum(c.value) else { return true }
        let got = e.ratingScore
        switch c.op { case .lte: return got <= want; case .eq: return got == want; default: return got >= want }
    case .year:
        guard let want = toNum(c.value) else { return true }
        guard let got = toNum(e.year) else { return false }
        switch c.op { case .lte: return got <= want; case .eq: return got == want; default: return got >= want }
    case .author:
        return (e.author ?? "").lowercased().contains(c.value.trimmingCharacters(in: .whitespaces).lowercased())
    case .theme:
        let v = c.value.trimmingCharacters(in: .whitespaces).lowercased()
        return c.op == .is_ ? e.themes.contains { $0.lowercased() == v }
                            : e.themes.contains { $0.lowercased().contains(v) }
    case .source:
        let v = c.value.trimmingCharacters(in: .whitespaces).lowercased()
        let src = (e.source ?? "").lowercased()
        return c.op == .is_ ? src == v : src.contains(v)
    case .haspdf:
        return e.hasPDF
    case .added:
        guard let days = toNum(c.value), let added = e.added else { return false }
        return now.timeIntervalSince1970 * 1000 - added <= days * 86_400_000
    }
}

/// Apply ready clauses; incomplete clauses are ignored so half-typed rows
/// don't blank the list. `now` is injectable for deterministic tests.
public func applyFilters(_ list: [Entry], _ clauses: [FilterClause],
                         match: FilterMatch, now: Date = Date()) -> [Entry] {
    let active = clauses.filter(clauseReady)
    guard !active.isEmpty else { return list }
    return list.filter { e in
        match == .all ? active.allSatisfy { test(e, $0, now: now) }
                      : active.contains { test(e, $0, now: now) }
    }
}

/// Short human label for a chip, e.g. "评分 ≥ 3".
public func clauseLabel(_ c: FilterClause) -> String {
    if c.field == .haspdf { return "有 PDF" }
    if c.field == .added { return "入库近 \(c.value) 天" }
    let opLabel: String
    switch c.op {
    case .gte: opLabel = "≥"; case .lte: opLabel = "≤"; case .eq: opLabel = "="
    case .contains: opLabel = "包含"; case .is_: opLabel = "是"
    case .yes: opLabel = ""; case .within: opLabel = ""
    }
    return "\(c.field.label) \(opLabel) \(c.value)".trimmingCharacters(in: .whitespaces)
}
```

- [ ] **Step 4: Run, verify passes**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter ListFilterTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/ListFilter.swift apple/Tests/MarpleKitTests/ListFilterTests.swift
git commit -m "feat(native): port flat list filters"
```

---

### Task 5: Theme index (`ThemeIndex.swift`)

**Files:**
- Create: `apple/Sources/MarpleKit/ThemeIndex.swift`
- Test: `apple/Tests/MarpleKitTests/ThemeIndexTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ThemeIndexTests.swift`:

```swift
import Testing
@testable import MarpleKit

@Suite struct ThemeIndexTests {
    func e(_ path: String, _ themes: [String]) -> Entry {
        Entry(path: path, type: .paperAnalysis, title: nil, author: nil, year: nil,
              ratingScore: 0, themes: themes, preview: "", hasPDF: false)
    }

    @Test func testCountsAndOrder() {
        let list = [e("a", ["econ", "history"]), e("b", ["econ"]), e("c", ["history"]),
                    e("d", ["econ"])]
        let idx = themeCounts(list)
        // econ:3 first (count desc), then history:2
        #expect(idx.map(\.theme) == ["econ", "history"])
        #expect(idx.map(\.count) == [3, 2])
    }

    @Test func testEqualCountsSortByName() {
        let list = [e("a", ["banana"]), e("b", ["apple"])]
        #expect(themeCounts(list).map(\.theme) == ["apple", "banana"])
    }

    @Test func testIgnoresEmptyThemeStrings() {
        let list = [e("a", ["", "  ", "econ"])]
        #expect(themeCounts(list).map(\.theme) == ["econ"])
    }
}
```

- [ ] **Step 2: Run, verify fails**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter ThemeIndexTests`
Expected: build error — `cannot find 'themeCounts'`.

- [ ] **Step 3: Implement `ThemeIndex.swift`**

```swift
import Foundation

public struct ThemeCount: Sendable, Equatable, Identifiable {
    public let theme: String
    public let count: Int
    public var id: String { theme }
}

/// Distinct themes across all entries with their occurrence counts, ordered by
/// count desc then locale-aware name asc.
public func themeCounts(_ entries: [Entry]) -> [ThemeCount] {
    var counts: [String: Int] = [:]
    for e in entries {
        for raw in e.themes {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            counts[t, default: 0] += 1
        }
    }
    return counts.map { ThemeCount(theme: $0.key, count: $0.value) }
        .sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.theme.compare(b.theme, options: [], range: nil,
                                   locale: Locale(identifier: "zh_Hans_CN")) == .orderedAscending
        }
}
```

- [ ] **Step 4: Run, verify passes**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter ThemeIndexTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/ThemeIndex.swift apple/Tests/MarpleKitTests/ThemeIndexTests.swift
git commit -m "feat(native): theme index (counts + ordering)"
```

---

### Task 6: Browse pane subset (`Browse.swift`)

**Files:**
- Create: `apple/Sources/MarpleKit/Browse.swift`
- Test: `apple/Tests/MarpleKitTests/BrowseTests.swift`

`Pane` is the middle column's selection. `entriesForPane` returns the base
subset before filter/sort: a `.type` pane keeps that type; a `.theme` pane keeps
entries (any type) carrying that theme; `.themesIndex` is not a list (returns []).

- [ ] **Step 1: Write the failing test**

Create `BrowseTests.swift`:

```swift
import Testing
@testable import MarpleKit

@Suite struct BrowseTests {
    func e(_ path: String, _ type: EntryType, themes: [String] = []) -> Entry {
        Entry(path: path, type: type, title: nil, author: nil, year: nil,
              ratingScore: 0, themes: themes, preview: "", hasPDF: false)
    }

    @Test func testTypePaneKeepsType() {
        let list = [e("a", .paperAnalysis), e("b", .note), e("c", .paperAnalysis)]
        #expect(entriesForPane(.type(.paperAnalysis), in: list).map(\.path) == ["a", "c"])
    }

    @Test func testThemePaneKeepsThemeAcrossTypes() {
        let list = [e("a", .paperAnalysis, themes: ["econ"]),
                    e("b", .note, themes: ["econ"]),
                    e("c", .note, themes: ["history"])]
        #expect(entriesForPane(.theme("econ"), in: list).map(\.path) == ["a", "b"])
    }

    @Test func testThemesIndexPaneHasNoList() {
        #expect(entriesForPane(.themesIndex, in: [e("a", .note)]).isEmpty)
    }
}
```

- [ ] **Step 2: Run, verify fails**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter BrowseTests`
Expected: build error — `cannot find 'entriesForPane'`.

- [ ] **Step 3: Implement `Browse.swift`**

```swift
import Foundation

public enum Pane: Hashable, Sendable {
    case type(EntryType)
    case themesIndex
    case theme(String)
}

/// Base subset for a pane, before filter/sort. `.themesIndex` is not a list view.
public func entriesForPane(_ pane: Pane, in entries: [Entry]) -> [Entry] {
    switch pane {
    case .type(let t):    return entries.filter { $0.type == t }
    case .theme(let name): return entries.filter { $0.themes.contains(name) }
    case .themesIndex:    return []
    }
}
```

- [ ] **Step 4: Run, verify passes**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter BrowseTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Browse.swift apple/Tests/MarpleKitTests/BrowseTests.swift
git commit -m "feat(native): browse pane subset (type/theme/themesIndex)"
```

---

### Task 7: `VaultClient.search` — DTOs, protocol, stub

**Files:**
- Modify: `apple/Sources/MarpleKit/VaultClient.swift`
- Test: `apple/Tests/MarpleKitTests/VaultClientStubTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `VaultClientStubTests.swift` (inside its `@Suite`):

```swift
    @Test func testStubSearchReturnsConfiguredHits() async throws {
        let hit = SearchHit(entry: Entry(path: "vault/p/a.md", type: .paperAnalysis,
                              title: "A", author: nil, year: nil, ratingScore: 0,
                              themes: [], preview: "", hasPDF: false),
                            score: 9, snippet: "…A…", source: "fulltext")
        let stub = StubVaultClient(entries: [], texts: [:], hits: [hit])
        let out = try await stub.search(SearchQuery(q: "a"))
        #expect(out.map { $0.entry.path } == ["vault/p/a.md"])
        #expect(out.first?.snippet == "…A…")
    }
```

- [ ] **Step 2: Run, verify fails**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter VaultClientStubTests`
Expected: build error — `cannot find 'SearchHit'` / `extra argument 'hits'`.

- [ ] **Step 3: Implement DTOs + protocol method + stub**

In `VaultClient.swift`, add the DTOs (top level):

```swift
public struct SearchQuery: Sendable, Equatable {
    public var q: String
    public var type: EntryType?
    public var minRating: Double?
    public var theme: String?
    public var limit: Int
    public init(q: String, type: EntryType? = nil, minRating: Double? = nil,
                theme: String? = nil, limit: Int = 80) {
        self.q = q; self.type = type; self.minRating = minRating
        self.theme = theme; self.limit = limit
    }
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public let entry: Entry
    public let score: Double
    public let snippet: String?
    public let source: String
    public var id: String { entry.path }
    public init(entry: Entry, score: Double, snippet: String?, source: String) {
        self.entry = entry; self.score = score; self.snippet = snippet; self.source = source
    }
}
```

Add to the `VaultClient` protocol:

```swift
    func search(_ query: SearchQuery) async throws -> [SearchHit]
```

Update `StubVaultClient` — add a stored `hits`, an updated init, and the method:

```swift
public struct StubVaultClient: VaultClient {
    public let entries: [Entry]
    public let texts: [String: String]
    public let hits: [SearchHit]
    public init(entries: [Entry], texts: [String: String], hits: [SearchHit] = []) {
        self.entries = entries; self.texts = texts; self.hits = hits
    }
    public func index() async throws -> [Entry] { entries }
    public func entryText(path: String) async throws -> String {
        guard let t = texts[path] else { throw VaultError.notFound(path) }
        return t
    }
    public func openInEditor(path: String, app: String) async throws {}
    public func search(_ query: SearchQuery) async throws -> [SearchHit] { hits }
}
```

- [ ] **Step 4: Run, verify passes**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter VaultClientStubTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/VaultClient.swift apple/Tests/MarpleKitTests/VaultClientStubTests.swift
git commit -m "feat(native): VaultClient.search DTOs + stub"
```

---

### Task 8: `HTTPVaultClient.search` → `/api/search`

**Files:**
- Modify: `apple/Sources/MarpleKit/HTTPVaultClient.swift`
- Test: `apple/Tests/MarpleKitTests/HTTPVaultClientTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `HTTPVaultClientTests`:

```swift
    @Test func testSearchBuildsQueryAndDecodesHits() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/search")
            let qs = req.url?.query ?? ""
            #expect(qs.contains("q=marx"))
            #expect(qs.contains("mode=fast"))
            #expect(qs.contains("entry_type=paper-analysis"))
            let body = #"{"items":[{"entry":{"path":"vault/p/a.md","type":"paper-analysis","preview":"","rating_score":0},"score":7.5,"snippet":"hi","source":"fulltext"}]}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let hits = try await makeClient().search(SearchQuery(q: "marx", type: .paperAnalysis))
        #expect(hits.map { $0.entry.path } == ["vault/p/a.md"])
        #expect(hits.first?.score == 7.5)
        #expect(hits.first?.source == "fulltext")
    }
```

- [ ] **Step 2: Run, verify fails**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter HTTPVaultClientTests`
Expected: build error — `value of type 'HTTPVaultClient' has no member 'search'`.

- [ ] **Step 3: Implement `search`**

Add to `HTTPVaultClient`:

```swift
    public func search(_ query: SearchQuery) async throws -> [SearchHit] {
        var comps = URLComponents(string: baseURL.absoluteString + "/api/search")!
        var items = [URLQueryItem(name: "q", value: query.q),
                     URLQueryItem(name: "mode", value: "fast"),
                     URLQueryItem(name: "limit", value: String(query.limit))]
        if let t = query.type { items.append(URLQueryItem(name: "entry_type", value: t.rawValue)) }
        if let r = query.minRating { items.append(URLQueryItem(name: "min_rating", value: String(r))) }
        if let th = query.theme { items.append(URLQueryItem(name: "theme", value: th)) }
        comps.queryItems = items
        let data = try await run(URLRequest(url: comps.url!))
        struct Wrapper: Decodable { let items: [SearchHit] }
        do { return try JSONDecoder().decode(Wrapper.self, from: data).items }
        catch { throw VaultError.decode("\(error)") }
    }
```

Make `SearchHit` `Decodable` — change its declaration in `VaultClient.swift` to:

```swift
public struct SearchHit: Sendable, Equatable, Identifiable, Decodable {
```

(`Entry` is already `Codable`, so the nested decode works; the keys
`entry/score/snippet/source` match the wire exactly.)

- [ ] **Step 4: Run, verify passes**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter HTTPVaultClientTests`
Expected: PASS.

- [ ] **Step 5: Full suite green + commit**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: all tests PASS.

```bash
git add apple/Sources/MarpleKit/HTTPVaultClient.swift apple/Sources/MarpleKit/VaultClient.swift apple/Tests/MarpleKitTests/HTTPVaultClientTests.swift
git commit -m "feat(native): HTTPVaultClient.search via /api/search (fast mode)"
```

---

### Task 9: Generalize `AppModel` for browse

**Files:**
- Modify: `apple/Sources/Marple/AppModel.swift`
- Test: `apple/Tests/MarpleKitTests/` — N/A (AppModel lives in the app target, not
  MarpleKit; it is validated by build + the manual GUI steps in Tasks 10–13).

This task is **logic wiring validated by `swift build`** (AppModel is `@MainActor`
`@Observable` in the executable target, which has no unit-test target under the
CLT setup). Keep the pure decisions in MarpleKit (already tested); AppModel only
composes them.

- [ ] **Step 1: Replace `AppModel` body**

Rewrite `apple/Sources/Marple/AppModel.swift` to:

```swift
import Foundation
import MarpleKit
import Observation

@Observable @MainActor
final class AppModel {
    let client: VaultClient
    var entries: [Entry] = []
    var status: String = ""

    // Browse state
    var pane: Pane = .type(.paperAnalysis)
    var sortClauses: [SortClause] = []
    var filterClauses: [FilterClause] = []
    var filterMatch: FilterMatch = .all
    var searchText: String = ""
    var searchHits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?

    // Reading state
    var openPath: String?
    var openBlocks: [RenderBlock] = []

    init(client: VaultClient) { self.client = client }

    // MARK: derived

    var counts: [EntryType: Int] {
        var c: [EntryType: Int] = [:]
        for e in entries { c[e.type, default: 0] += 1 }
        return c
    }

    var themeIndex: [ThemeCount] { themeCounts(entries) }

    /// The middle-column list: search results when searching, else the
    /// pane subset run through filters then sort.
    var visibleEntries: [Entry] {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return searchHits.map(\.entry)
        }
        let base = entriesForPane(pane, in: entries)
        let filtered = applyFilters(base, filterClauses, match: filterMatch)
        return sortEntries(filtered, by: sortClauses)
    }

    // MARK: actions

    func loadIndex() async {
        do {
            entries = try await client.index()
            status = "\(entries.count) entries"
            print("[marple] index loaded: \(entries.count) entries")
        } catch {
            status = "index failed: \(error)"
            print("[marple] index FAILED: \(error)")
        }
    }

    func select(pane newPane: Pane) {
        pane = newPane
        searchText = ""; searchHits = []
        print("[marple] pane -> \(newPane)")
    }

    /// Debounced server search scoped to the current type pane (nil type → all).
    func runSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = []; return }
        let type: EntryType? = { if case .type(let t) = pane { return t } else { return nil } }()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let hits = try await self?.client.search(SearchQuery(q: q, type: type)) ?? []
                if Task.isCancelled { return }
                self?.searchHits = hits
                print("[marple] search '\(q)' -> \(hits.count) hits")
            } catch {
                self?.status = "search failed: \(error)"
                print("[marple] search FAILED '\(q)': \(error)")
            }
        }
    }

    func open(_ path: String) async {
        openPath = path
        do {
            let raw = try await client.entryText(path: path)
            openBlocks = MarkdownModel.blocks(from: Frontmatter.split(raw).body)
            print("[marple] open \(path) -> \(openBlocks.count) blocks (\(raw.count) chars)")
        } catch {
            openBlocks = [.paragraph([.text("load failed: \(error)")])]
            print("[marple] open FAILED \(path): \(error)")
        }
    }

    func reloadOpen() async {
        if let p = openPath { print("[marple] watcher reload \(p)"); await open(p) }
    }

    func follow(_ target: String) async {
        if let hit = WikiResolver.resolve(target, in: entries) {
            print("[marple] follow [[\(target)]] -> \(hit.path)")
            await open(hit.path)
        } else {
            status = "unresolved [[\(target)]]"
            print("[marple] follow [[\(target)]] -> UNRESOLVED")
        }
    }

    func openExternally() async {
        guard let p = openPath else { return }
        do {
            try await client.openInEditor(path: p, app: "")
            print("[marple] openInEditor \(p)")
        } catch {
            status = "open-in-editor failed: \(error)"
            print("[marple] openInEditor FAILED \(p): \(error)")
        }
    }
}
```

- [ ] **Step 2: Build (SidebarView will not compile yet — that's Task 10)**

The old `SidebarView` references `model.papers`, now removed. Expect a build
failure here pointing at `SidebarView.swift`. That is the boundary between this
task and the next; do not patch `SidebarView` in this task.

Run: `cd apple && swift build`
Expected: error in `SidebarView.swift` — `value of type 'AppModel' has no member 'papers'`.

- [ ] **Step 3: Commit (logic-only; UI follows)**

```bash
git add apple/Sources/Marple/AppModel.swift
git commit -m "feat(native): generalize AppModel for typed browse + search"
```

---

### Task 10: Typed sidebar + entry-list column

**Files:**
- Modify: `apple/Sources/Marple/SidebarView.swift`
- Create: `apple/Sources/Marple/EntryRow.swift`
- Create: `apple/Sources/Marple/EntryListView.swift`

- [ ] **Step 1: Rewrite `SidebarView.swift`**

```swift
import SwiftUI
import MarpleKit

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.pane },
            set: { if let p = $0 { model.select(pane: p) } }
        )) {
            Section("物件") {
                ForEach(EntryType.modeled, id: \.self) { t in
                    Label {
                        HStack {
                            Text(t.label)
                            Spacer()
                            Text("\(model.counts[t] ?? 0)")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: { Image(systemName: icon(for: t)) }
                    .tag(Pane.type(t))
                }
            }
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
            }
        }
        .navigationTitle("Marple")
    }

    private func icon(for t: EntryType) -> String {
        switch t {
        case .paperAnalysis:  return "doc.text"
        case .bookOverview:   return "book"
        case .authorProfile:  return "person"
        case .topicSynthesis: return "square.stack.3d.up"
        case .chapterSummary: return "list.bullet.rectangle"
        case .note:           return "note.text"
        case .other:          return "questionmark.square.dashed"
        }
    }
}
```

- [ ] **Step 2: Create `EntryRow.swift`**

```swift
import SwiftUI
import MarpleKit

struct EntryRow: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title ?? "(untitled)").font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                if let a = entry.author, !a.isEmpty {
                    Text(a).lineLimit(1)
                }
                if let y = entry.year, !y.isEmpty {
                    Text(y)
                }
                if entry.ratingScore > 0 {
                    Text(String(repeating: "★", count: Int(entry.ratingScore.rounded())))
                        .foregroundStyle(.yellow)
                }
                if entry.hasPDF { Image(systemName: "doc.richtext").foregroundStyle(.secondary) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .tag(entry.path)
    }
}
```

- [ ] **Step 3: Create `EntryListView.swift`**

```swift
import SwiftUI
import MarpleKit

struct EntryListView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(model.visibleEntries, selection: Binding(
                get: { model.openPath },
                set: { if let p = $0 { Task { await model.open(p) } } }
            )) { entry in
                EntryRow(entry: entry)
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch model.pane {
        case .type(let t):   return "\(t.label) (\(model.visibleEntries.count))"
        case .theme(let n):  return "主题: \(n) (\(model.visibleEntries.count))"
        case .themesIndex:   return "主题"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("检索 标题/作者/主题…", text: Binding(
                    get: { model.searchText },
                    set: { model.searchText = $0; model.runSearch() }
                ))
                .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = ""; model.runSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            sortMenu
            filterMenu
        }
        .padding(8)
        .disabled(isThemesIndex)   // header is meaningless on the themes index pane
        .opacity(isThemesIndex ? 0.4 : 1)
    }

    private var isThemesIndex: Bool { if case .themesIndex = model.pane { return true } else { return false } }

    private var sortMenu: some View {
        Menu {
            Button("默认顺序") { model.sortClauses = [] }
            Divider()
            ForEach(SortField.allCases, id: \.self) { f in
                Menu(f.label) {
                    Button("升序 ↑") { model.sortClauses = [SortClause(field: f, dir: .asc)] }
                    Button("降序 ↓") { model.sortClauses = [SortClause(field: f, dir: .desc)] }
                }
            }
        } label: {
            Label(sortLabel, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var sortLabel: String {
        guard let c = model.sortClauses.first else { return "排序" }
        return "\(c.field.label)\(c.dir == .asc ? "↑" : "↓")"
    }

    private var filterMenu: some View {
        Menu {
            Button("清除筛选") { model.filterClauses = [] }
            Divider()
            Menu("评分 ≥") {
                ForEach([1, 2, 3, 4], id: \.self) { r in
                    Button("★ \(r)+") {
                        setSingle(.rating, .gte, String(r))
                    }
                }
            }
            Toggle("仅含 PDF", isOn: Binding(
                get: { model.filterClauses.contains { $0.field == .haspdf } },
                set: { on in
                    model.filterClauses.removeAll { $0.field == .haspdf }
                    if on { model.filterClauses.append(FilterClause(field: .haspdf, op: .yes, value: "")) }
                }
            ))
        } label: {
            Label(model.filterClauses.isEmpty ? "筛选" : "筛选(\(model.filterClauses.count))",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func setSingle(_ field: FilterField, _ op: FilterOp, _ value: String) {
        model.filterClauses.removeAll { $0.field == field }
        model.filterClauses.append(FilterClause(field: field, op: op, value: value))
    }
}
```

- [ ] **Step 4: Build**

Run: `cd apple && swift build`
Expected: builds; `MarpleApp.swift` still references the old two-column layout
(it compiles — `DocView`/`SidebarView` exist), but the new `EntryListView` is not
yet wired. Build should SUCCEED. If `MarpleApp` references something removed,
it will be fixed in Task 12. (It does not — `SidebarView(model:)` still exists.)

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/Marple/SidebarView.swift apple/Sources/Marple/EntryRow.swift apple/Sources/Marple/EntryListView.swift
git commit -m "feat(native): typed sidebar + entry-list column (search/sort/filter)"
```

---

### Task 11: 主题 cross-cut view

**Files:**
- Create: `apple/Sources/Marple/ThemesView.swift`

- [ ] **Step 1: Create `ThemesView.swift`**

```swift
import SwiftUI
import MarpleKit

struct ThemesView: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(model.themeIndex) { tc in
                    Button { model.select(pane: .theme(tc.theme)) } label: {
                        HStack {
                            Image(systemName: "tag")
                            Text(tc.theme).lineLimit(1)
                            Spacer()
                            Text("\(tc.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("主题 (\(model.themeIndex.count))")
    }
}
```

- [ ] **Step 2: Build**

Run: `cd apple && swift build`
Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add apple/Sources/Marple/ThemesView.swift
git commit -m "feat(native): 主题 cross-cut grid view"
```

---

### Task 12: Three-column layout in `MarpleApp`

**Files:**
- Modify: `apple/Sources/Marple/MarpleApp.swift`

- [ ] **Step 1: Swap the split view**

In `MarpleApp.swift`, replace the `NavigationSplitView { … } detail: { … }` block
inside `if let model = state.model {` with a three-column layout whose middle
column switches on the pane:

```swift
                if let model = state.model {
                    NavigationSplitView {
                        SidebarView(model: model).frame(minWidth: 220)
                    } content: {
                        Group {
                            if case .themesIndex = model.pane {
                                ThemesView(model: model)
                            } else {
                                EntryListView(model: model)
                            }
                        }
                        .frame(minWidth: 320)
                    } detail: {
                        DocView(model: model)
                    }
                }
```

- [ ] **Step 2: Build**

Run: `cd apple && swift build`
Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add apple/Sources/Marple/MarpleApp.swift
git commit -m "feat(native): three-column browse layout (types | list | doc)"
```

---

### Task 13: Full verification + GUI validation + handoff

**Files:**
- Modify: `docs/superpowers/2026-05-23-marple-native-p1-handoff.md` (append a P2 section)
  or create `docs/superpowers/2026-05-23-marple-native-p2-handoff.md`.

- [ ] **Step 1: Full test suite green**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: all tests PASS (P1's ~28 + the new ListSort/ListFilter/ThemeIndex/Browse/
search/Entry tests). Record the count.

- [ ] **Step 2: Clean build**

Run: `cd apple && swift build`
Expected: builds with no errors.

- [ ] **Step 3: Launch for manual GUI validation**

Run (background): `cd apple && swift run Marple > /tmp/marple-app.log 2>&1 &`
Then ask the user to verify, while you tail `/tmp/marple-app.log`:
  - sidebar shows 6 types with non-zero counts + 主题 with a count;
  - clicking each type switches the middle list and updates its title/count;
  - sort menu reorders (e.g. 评分↓ floats rated entries up, blanks last);
  - 评分≥3 filter and 仅含 PDF toggle shrink the list correctly;
  - typing in the search box returns ranked hits (check `[marple] search … -> N hits`);
  - 主题 → grid of themes → clicking a theme shows a cross-type filtered list;
  - selecting an entry still opens the reader; wikilinks + 用外部编辑器打开 still work (P1 regression check).
Stop the run when done: `pkill -f "debug/Marple"; pkill -f "release/reader-api"`.

- [ ] **Step 4: Write the P2 handoff/work-log**

Document: what shipped, the new MarpleKit units + tests, the three-column
layout, search mode = fast only (balanced/deep deferred to P5), any bugs found
during GUI validation and how they were fixed, and the next phase (P3: right
panel 目录/信息/统计, PropertyPanel metadata write-back, tabs/history). Mirror the
P1 handoff's structure.

- [ ] **Step 5: Commit + update memory**

```bash
git add docs/superpowers/2026-05-23-marple-native-p2-handoff.md
git commit -m "docs(handoff): P2 browse work log"
```

Then update the `marple-native-initiative` memory's P-status line to "P2 done".

---

## Self-Review notes

- **Spec coverage (§11 P2):** lexical search → Tasks 7/8 + AppModel.runSearch;
  sort → Task 3; filter/rating → Task 4; all 6 types → Tasks 2/10; 主题 cross-cut
  → Tasks 5/6/11. ✓
- **Boundary discipline (§4):** search added to `VaultClient`; UI uses only the
  protocol + DTOs; `HTTPVaultClient` is the only transport-aware unit. ✓
- **Deferred (not in P2):** balanced/deep search modes, card-grid presentation
  (kept native `List` for virtualization/scroll feel — the #1 motivation),
  full filter-builder UI (P2 ships rating≥ + 仅PDF; the ported `ListFilter` is
  general for later), tabs/history/right-panel/metadata write (P3+).
- **Type consistency:** `Pane`, `SortClause`/`SortField`/`SortDir`,
  `FilterClause`/`FilterField`/`FilterOp`/`FilterMatch`, `SearchQuery`/`SearchHit`,
  `ThemeCount` names are used identically across tasks. `applyFilters` signature
  `(_, _, match:, now:)` and `sortEntries(_, by:)` are stable. ✓
- **CLT test invocation** includes the framework search path in every test step. ✓
```
