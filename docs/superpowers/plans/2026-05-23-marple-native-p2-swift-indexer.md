# Phase 2 — Pure-Swift Indexer (Full Parity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Port `rust/reader-core/src/indexer.rs` to pure Swift so the app builds & maintains `<workspaceRoot>/.marple/index.sqlite` in-process, then remove the Rust sidecar entirely.

**Architecture:** A Swift `VaultIndexer` (in `MarpleKit`) walks the vault, parses each markdown file's frontmatter+body into an `IndexedEntry`, and writes the SQLite schema (entries + entry_text + entry_themes + entry_search + entry_trigram + meta) via **GRDB `DatabasePool`** (WAL, single writer). A full build writes to a temp DB and atomically renames it into place; incremental reconcile diffs file mtimes against the `entries` table and upserts/deletes changed paths. The existing FSEvents `VaultWatcher` triggers debounced reconciles; a boot reconcile runs at launch. The app stops launching `SidecarProcess`. `IndexDatabase` (Phase 1) remains the read path.

**Tech Stack:** Swift 6, GRDB (already added), **Yams** (new — YAML frontmatter), Foundation, the existing `Frontmatter`/`Wikilink`/`VaultWatcher`/`IndexDatabase` primitives.

**THIS IS A PORT.** For every function, mirror the named Rust function in `rust/reader-core/src/indexer.rs` (or `lib.rs`) EXACTLY. The parity tests in each task encode the required behavior; when a detail is ambiguous, match the Rust source. Read the porting spec context below before starting any task.

---

## Parity reference cheat-sheet (from a full read of indexer.rs)

- **Workspace-relative path** (`slash_relative`): strip `<workspaceRoot>/` prefix, join with `/`. The PK across all tables.
- **canonical_type** (indexer.rs:940-963) alias map → see Task 3. `""` and `"A"` → skip entry (SkippedUnknownType). Unknown non-empty → passed through (becomes `.other`).
- **Walk** (`walk_markdown` :610-628): recurse `vault/`, skip any entry whose name starts with `.`, collect files with extension exactly `md`.
- **Frontmatter fence**: file must start `---\n` or `---\r\n`; body begins after the line that trims to `---`. Parser = serde_yaml mapping, else `parse_lenient_mapping` (:667-714).
- **entries columns & derivation, FTS contents, reconcile algorithm**: detailed per-task below.
- index DB path = `<workspaceRoot>/.marple/index.sqlite`; sources dir = `<workspaceRoot>/sources`; trash excluded by the `.`-prefix skip.
- Tests: Swift Testing (`@Suite`/`@Test`/`#expect`), run `cd apple && swift test`.

## File Structure (all under `apple/Sources/MarpleKit/` unless noted)

- `Package.swift` — add Yams.
- `YamlFrontmatter.swift` — parse raw frontmatter → ordered `[(String, YamlValue)]` mapping (serde_yaml + lenient fallback); `YamlValue` enum.
- `IndexFields.swift` — field accessors + transforms (`field`, `textValue`, `truthyText`, `intValue`, `themeArray`, `flattenAuthor`, `fieldJSON`, `jsonCell`, `truthyJSON`, `stripWiki`, `canonicalType`, `ratingScore`).
- `IndexTitles.swift` — title/localisation/douban helpers.
- `IndexBody.swift` — `normalizeBodyForSearch`, `firstParagraph`, `firstHeading`, `firstChineseH1`, `searchText`, body/CJK helpers.
- `SourceResolver.swift` — `loadSourceSlugs`, `bookSlug`, pdf_slug, `fuzzyPickSource`, `hasPdf`.
- `GitDates.swift` — `gitAddedDates`, `gitAddedDate`.
- `IndexedEntry.swift` — the row struct + `buildIndexedEntry` + `BuildOutcome`.
- `IndexWriter.swift` — GRDB schema DDL + inserts.
- `VaultIndexer.swift` — full build (temp+rename) + incremental reconcile + write lock.
- `Sources/Marple/MarpleApp.swift` — boot+watch reconcile, stop launching sidecar.
- Tests mirror each source file: `Tests/MarpleKitTests/<Name>Tests.swift`.

---

### Task 1: Yams dependency + frontmatter parser (`YamlFrontmatter.swift`)

**Files:** Modify `apple/Package.swift`; Create `apple/Sources/MarpleKit/YamlFrontmatter.swift`; Test `apple/Tests/MarpleKitTests/YamlFrontmatterTests.swift`.

**Rust to mirror:** `parse_file` (:611-650, fence detection — but Swift `Frontmatter.split` already does this; reuse it), `serde_yaml` parse + `parse_lenient_mapping` (:653-721), `parse_scalar`/`unquote`.

**Swift contract:**
```swift
public indirect enum YamlValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case sequence([YamlValue])
    case mapping([(String, YamlValue)])   // ordered, preserves insertion order
}

public enum YamlFrontmatter {
    /// Parse the raw frontmatter string (the part between --- fences, as returned
    /// by Frontmatter.split) into an ordered top-level mapping. Mirrors Rust:
    /// try a full YAML parse first; on failure or non-mapping, fall back to the
    /// lenient line parser. Returns [] when there is no usable mapping.
    public static func parseMapping(_ raw: String) -> [(String, YamlValue)]
}
```

**Behavior to match (from `parse_lenient_mapping`):** skip blank + `#` lines; `- item` appends to the current sequence key; `key: value` splits on FIRST ASCII `:`; keys with leading whitespace skipped; `parse_scalar` tries YAML then `unquote` (strip matching `"`/`'`); a key with empty value opens a sequence key for following `- ` items. **ASCII `:` only — full-width `：` is NOT a separator.**

- [ ] Step 1: Add Yams to `Package.swift` (dependency `https://github.com/jpsim/Yams.git` from `5.0.0`; add product `Yams` to the `MarpleKit` target). Run `cd apple && swift build` to resolve.
- [ ] Step 2: Write `YamlFrontmatterTests.swift` (failing). Concrete cases (mirror indexer.rs tests :1634-1649 + spec):
  - Well-formed: `"type: paper-analysis\ntitle: Hello\nyear: 2019\nthemes:\n  - ai\n  - ethics"` → mapping has `type`="paper-analysis", `title`="Hello", `year`=int 2019, `themes`=sequence(["ai","ethics"]).
  - Lenient rescue (unquoted inner colon): `"book: Understanding Dogs: A Study\ntype: book-overview"` → `book`=string "Understanding Dogs: A Study", `type`="book-overview". (Full YAML fails on the inner colon; lenient must rescue BOTH keys.)
  - Quoted: `title: \"Hello: World\"` → `title`="Hello: World".
  - CJK colon NOT parsed: `"作者：张三"` as a line → NOT a key (no ASCII colon) → ignored.
  - Comment + blank lines skipped.
  - Flow array: `themes: [ai, ethics]` → sequence(["ai","ethics"]).
  - Empty input / no mapping → `[]`.
- [ ] Step 3: Run tests → FAIL (no `YamlFrontmatter`). `cd apple && swift test --filter YamlFrontmatterTests`.
- [ ] Step 4: Implement. Use Yams `Yams.load`/`Node` for the primary parse, converting Yams `Node` → `YamlValue` (preserve mapping order via `Node.mapping`). On Yams throw OR non-mapping result, run the lenient line parser ported from `parse_lenient_mapping`. READ the Rust function and match it line-for-line.
- [ ] Step 5: Run → PASS. Full `swift test` green.
- [ ] Step 6: Commit (stage `Package.swift`, `Package.resolved`, `YamlFrontmatter.swift`, `YamlFrontmatterTests.swift`): `feat(native): YAML frontmatter parser (Yams + lenient fallback) for the Swift indexer`.

---

### Task 2: Field accessors & transforms (`IndexFields.swift`)

**Files:** Create `IndexFields.swift`; Test `IndexFieldsTests.swift`.

**Rust to mirror:** `field`/`field_*` (:966-1015 area), `text_value` (:1086-1094), `truthy_field_text` (:987-989), `int_value` (:1096-1102), `theme_array` (:1104-1109), `flatten_author` (:924-938), `field_json`/`json_cell`/`truthy_json`/`yaml_to_json` (:1065-1113), `strip_wiki` (:901-922), `canonical_type` (:940-963), `rating_score` (:886-899).

**Swift contract (free functions or an enum namespace `IndexFields`):**
```swift
func field(_ map: [(String, YamlValue)], _ name: String) -> YamlValue?      // first match, case-sensitive
func textValue(_ v: YamlValue?) -> String?      // null→nil; string→self; bool→"true"/"false"; number→stringified; seq/map→JSON
func truthyText(_ map: [(String,YamlValue)], _ key: String) -> String?      // textValue of field, empty→nil
func intValue(_ v: YamlValue?) -> Int64?
func themeArray(_ v: YamlValue?) -> [String]?   // only a sequence; map each via textValue; else nil
func flattenAuthor(_ v: YamlValue?) -> String?  // null→nil; seq→join nonempty stripWiki'd with ", "; scalar→stripWiki(textValue)
func fieldJSONCell(_ v: YamlValue?) -> String?  // yaml→JSON string (serde_json::to_string equiv); null→nil
func truthyJSONCell(_ v: YamlValue?) -> String? // filter null/false/0.0/"" → nil; else JSON string
func stripWiki(_ s: String) -> String           // [[t|d]]→d, [[t]]→t, brackets removed
func canonicalType(_ raw: String) -> String?     // alias map; "" and "A" → nil; unknown nonempty → raw
func ratingScore(_ v: YamlValue?) -> Double      // number→f64; string→count '★', else parse, else 0; other→0
```

**canonicalType alias map (exact):** paper|paper-summary|article-analysis|journal-article|journal-article-analysis→paper-analysis; author→author-profile; book|book-analysis|monograph|monograph-analysis|overview→book-overview; chapter|book-chapter|book_chapter|chapter-analysis→chapter-summary; journal-synthesis|snowball-synthesis|citation-snowball-synthesis|reading-list|research-note|concept-note→topic-synthesis; ""|"A"→nil; else→raw.

- [ ] Step 1: Write `IndexFieldsTests.swift` (failing) with concrete cases per function:
  - `canonicalType("paper")`=="paper-analysis"; `("book_chapter")`=="chapter-summary"; `("note")`=="note"; `("")`==nil; `("A")`==nil; `("weird")`=="weird".
  - `ratingScore(.string("★★★"))`==3; `(.string("★★"))`==2; `(.number 4)`==4; `(.string("4.5"))`==4.5; `(.string("foo"))`==0; `(nil)`==0.
  - `stripWiki("[[vault/x.md|Display]]")`=="Display"; `("[[Target]]")`=="Target"; `("plain")`=="plain".
  - `flattenAuthor(.sequence([.string("A"),.string("B")]))`=="A, B"; `(.string("[[x|Solo]]"))`=="Solo"; `(.null)`==nil.
  - `themeArray(.sequence([.string("ai"),.string("ethics")]))`==["ai","ethics"]; `(.string("ai"))`==nil.
  - `textValue(.bool(true))`=="true"; `(.int(3))`=="3"; `(.null)`==nil; `(.sequence([.int(1)]))`=="[1]".
  - `fieldJSONCell(.int(2019))`=="2019"; `(.string("2019"))`=="\"2019\""; `(.sequence([.int(2010),.int(2015)]))`=="[2010,2015]"; `(.null)`==nil.
  - `truthyJSONCell(.bool(false))`==nil; `(.int(0))`==nil; `(.string(""))`==nil; `(.string("★★"))`=="\"★★\"".
  - `intValue(.string("12"))`==12; `(.double(3.9))`==3; `(.string("x"))`==nil.
- [ ] Step 2: Run → FAIL.
- [ ] Step 3: Implement, mirroring the Rust functions. For `fieldJSONCell` match `serde_json::to_string` formatting (compact, no spaces: `[2010,2015]`). Use a small YamlValue→JSON serializer.
- [ ] Step 4: Run → PASS; full suite green.
- [ ] Step 5: Commit (`IndexFields.swift`, `IndexFieldsTests.swift`): `feat(native): frontmatter field accessors + transforms (canonicalType, ratingScore, stripWiki, …)`.

---

### Task 3: Title / localisation / douban helpers (`IndexTitles.swift`)

**Files:** Create `IndexTitles.swift`; Test `IndexTitlesTests.swift`.

**Rust to mirror:** `title_en_value` (:991-995), `title_cn_value` (:997-1015) incl. `first_chinese_h1` (:859-875) + CJK ranges (:877-884), `translation_title_cn_value` (:1017-1021), `localisation_zh` (:1030-1040), `translation_douban_url_value` (:1023-1028), `douban_url_from_value` (:1042-1047), `normalise_douban_url` (:1049-1063).

**Swift contract:**
```swift
func titleEn(_ map: [(String,YamlValue)]) -> String?       // title_en | chapter_title_en → stripWiki
func titleCn(_ map: [(String,YamlValue)], type: String, title: String?, body: String) -> String?
    // title_cn|title_zh|chapter_title_cn|chapter_title_zh → stripWiki; for book-overview only,
    // fall back to firstChineseH1(body) if it differs from `title`.
func translationTitleCn(_ map: [(String,YamlValue)]) -> String?     // localisations.zh.title → stripWiki
func translationDoubanUrl(_ map: [(String,YamlValue)]) -> String?   // localisations.zh.douban_url | douban_url | cndouban → normalise
func firstChineseH1(_ body: String) -> String?
func isCJK(_ scalar: Unicode.Scalar) -> Bool   // ONLY U+3400–U+4DBF, U+4E00–U+9FFF, U+F900–U+FAFF
func normaliseDoubanUrl(_ s: String) -> String?  // http(s)→self; digits→https://book.douban.com/subject/{id}/; else nil
```

- [ ] Step 1: Write `IndexTitlesTests.swift` (failing):
  - `normaliseDoubanUrl("12345")`=="https://book.douban.com/subject/12345/"; `("https://x")`=="https://x"; `("")`==nil; `("abc")`==nil.
  - `isCJK` true for "中" (U+4E2D), false for "あ" (Hiragana) and "A".
  - `firstChineseH1("# English\n# 中文标题\n")`=="中文标题"; ignores non-CJK H1.
  - `titleCn` for type "book-overview" with no cn frontmatter but body has `# 中文` and title "English" → "中文"; if title == the H1, → nil.
  - `titleEn`/`translationTitleCn` from a `localisations:\n  zh:\n    title: 译名\n    douban_url: 12345` mapping (parse via YamlFrontmatter in the test).
- [ ] Step 2: Run → FAIL. Step 3: Implement mirroring Rust (note `localisation_zh` accepts a Mapping or a Sequence-of-Mappings; douban_url_from_value takes first match in a sequence). Step 4: PASS + full suite. Step 5: Commit: `feat(native): title/localisation/douban frontmatter helpers`.

---

### Task 4: Body helpers (`IndexBody.swift`)

**Files:** Create `IndexBody.swift`; Test `IndexBodyTests.swift`.

**Rust to mirror:** `normalize_body_for_search` (:1588-1595), `first_paragraph` (:739-767) incl. `is_kv_label` (:828-838), `first_heading` (:841-857), `search_text` (:1597-1604).

**Swift contract:**
```swift
func normalizeBodyForSearch(_ body: String) -> String   // CRLF→LF, trim each line, drop blank lines, join "\n"
func bodyLen(_ body: String) -> Int                      // normalizeBodyForSearch(body).unicodeScalars.count
func firstParagraph(_ body: String) -> String           // preview, ≤800 chars (see rules)
func firstHeading(_ body: String) -> String?
func searchText(_ parts: [String]) -> String            // per-part collapse whitespace, drop empty, join "\n"
func isKVLabel(_ line: String) -> Bool                   // **label**：value or **label**: value
```

**firstParagraph rules (match exactly):** split normalized-for-display body on `\n\n` after CRLF→LF; skip empty paragraphs, ones starting `#`, ones starting `---`, single `**...**` blocks <80 chars, and paragraphs whose first line `isKVLabel`. For kept paragraphs, collapse internal whitespace (`split on whitespace` join " ") and join paragraphs with " ", accumulate up to **800 chars** (Unicode scalar count), truncate to 800.

- [ ] Step 1: `IndexBodyTests.swift` (failing): 
  - `normalizeBodyForSearch("a\r\n\n  b  \n\nc")`=="a\nb\nc"; `bodyLen` of CJK string counts scalars.
  - `searchText(["a b","","c"])`=="a b\nc" (note the "a b" keeps single internal space).
  - `firstHeading("intro\n## Heading\n")`=="Heading" (or per Rust — any-level heading; verify Rust takes the heading text after `#`s).
  - `isKVLabel("**作者**：张三")`==true; `("**Author**: X")`==true; `("plain")`==false.
  - `firstParagraph`: a doc whose first block is a kv-label list then a real paragraph → returns the real paragraph text; a doc with only headings → "".
  - 800-char cap: long body → result scalar count ≤ 800.
- [ ] Step 2-5: FAIL → implement (mirror Rust) → PASS → full suite → Commit: `feat(native): body/preview/search-text helpers for the indexer`.

---

### Task 5: PDF source resolution (`SourceResolver.swift`)

**Files:** Create `SourceResolver.swift`; Test `SourceResolverTests.swift`.

**Rust to mirror:** `load_source_slugs` (search `load_source_slugs` in indexer.rs), `book_slug` (:1138-1143), pdf_slug derivation (:158-173), and **`fuzzy_pick_source`** in `lib.rs:1121-1172` + its helpers (stopwords, `is_year_token`, token split, Jaccard).

**Swift contract:**
```swift
func loadSourceSlugs(sourcesDir: String) -> Set<String>   // file stems of *.pdf (case-insensitive ext)
func bookSlug(_ rel: String) -> String?                   // first path comp after "vault/books/"
func pdfSlug(type: String, rel: String, fileStem: String) -> String?  // paper→stem; book-overview→bookSlug; else nil
func hasPDF(slug: String, sourceSlugs: Set<String>) -> Bool   // exact contains OR fuzzyPickSource != nil
func fuzzyPickSource(_ slug: String, _ candidates: Set<String>) -> String?
```

**fuzzy_pick_source rules (match exactly):** lowercase tokenization on non-alphanumeric; stopwords = the,of,a,an,and,to,in,on,for,from,at,by,with,de,la,le,el,und,der,die,das; require same leading lastname token; ≥2 shared significant title tokens; Jaccard ≥ 0.6; accept if (identical title token sets) OR (year within ±5, year = a 4-ASCII-digit token); choose a single winner OR score gap > 0.15.

- [ ] Step 1: `SourceResolverTests.swift` (failing) — mirror the Rust tests for `fuzzy_pick_source` (find them in `rust/reader-core/src/lib.rs` tests and replicate the exact inputs/expected). Plus: `bookSlug("vault/books/smith-dog-2020/ch3.md")`=="smith-dog-2020"; `pdfSlug` for paper-analysis returns the stem; `hasPDF` exact match true; non-match false; a known fuzzy match from the Rust tests true.
- [ ] Step 2: Run → FAIL. Step 3: Implement; READ `lib.rs:1121-1172` and port the algorithm and helpers verbatim. Step 4: PASS + full suite. Step 5: Commit: `feat(native): PDF source slug + fuzzy matching (has_pdf parity)`.

---

### Task 6: Git-derived added dates (`GitDates.swift`)

**Files:** Create `GitDates.swift`; Test `GitDatesTests.swift`.

**Rust to mirror:** `git_added_dates` (:769-810 area) and `git_added_date` (single path). Command: `git log --diff-filter=A --reverse --format=%aI --name-only -- vault` run in the workspace root; parse RFC3339 author-dates; map each listed path → epoch-ms of its FIRST appearance; missing → 0.

**Swift contract:**
```swift
func gitAddedDates(workspaceRoot: String) -> [String: Int64]   // path(relative as git prints) → epoch-ms, first wins
func gitAddedDate(workspaceRoot: String, relPath: String) -> Int64   // 0 if none/failure
```
Implementation: run `git` via `Process` (`/usr/bin/env git ...`), capture stdout, parse. RFC3339 → epoch-ms via ISO8601DateFormatter (with `.withFractionalSeconds` fallback). Any failure → empty map / 0.

- [ ] Step 1: `GitDatesTests.swift` (failing) — integration test: create a temp dir, `git init`, set user.email/name (locally, `-c`), add a `vault/papers/a.md`, commit; assert `gitAddedDates(tmp)["vault/papers/a.md"]` > 0 and `gitAddedDate(tmp, "vault/papers/a.md")` equals it; assert a non-committed path → 0; assert a non-git dir → empty/0 (no crash).
- [ ] Step 2: Run → FAIL. Step 3: Implement (mirror Rust flags exactly). Step 4: PASS + full suite. Step 5: Commit: `feat(native): git-derived 'added' dates (first-commit epoch-ms)`.

---

### Task 7: IndexedEntry + buildIndexedEntry (`IndexedEntry.swift`)

**Files:** Create `IndexedEntry.swift`; Test `IndexedEntryTests.swift`.

**Rust to mirror:** `IndexedEntry` struct + `build_indexed_entry` (:108-243) + `BuildOutcome`.

**Swift contract:**
```swift
public struct IndexedEntry: Sendable, Equatable { /* one field per entries column, see spec section 1 */ }
public enum BuildOutcome: Sendable, Equatable {
    case indexed(IndexedEntry)
    case skippedNoType
    case skippedUnknownType
    case skipped            // no frontmatter fence
}
/// Parse one file's full text into an outcome. `rel` = workspace-relative path,
/// `fileStem` = filename without .md, `sourceSlugs` from Task 5, `mtimeMs` from fs.
/// `added` is set separately by the caller (full build) — initialize to 0 here.
func buildIndexedEntry(text: String, rel: String, fileStem: String,
                       sourceSlugs: Set<String>, mtimeMs: Int64?) -> BuildOutcome
```

Wire together Tasks 1-5: `Frontmatter.split` → `YamlFrontmatter.parseMapping` → fields. Compute every column per spec section 1 (book only for chapter-summary; title note-vs-other rule; title_en/cn; author flatten; year_json; rating_json+rating_score; themes_json; topic/source/doi/publisher/isbn; translation_*; chapters_analyzed; annotates; created; pdf_slug+has_pdf; mtime; preview=firstParagraph; body_len; added=0). Build `searchText` from the 9 parts (Task 4). Return `.skipped` if no fence, `.skippedNoType` if no `type` key, `.skippedUnknownType` if canonicalType is nil.

- [ ] Step 1: `IndexedEntryTests.swift` (failing) with 3-4 realistic fixture documents (a paper-analysis with rating ★★★ + themes + year; a note whose title comes from first heading; a book-overview with a Chinese H1 and no title_cn; a file with no frontmatter → `.skipped`; a file with `type:` missing → `.skippedNoType`; `type: A` → `.skippedUnknownType`). Assert the resulting IndexedEntry fields match expected values.
- [ ] Step 2: FAIL → Step 3: implement (mirror build_indexed_entry) → Step 4: PASS + full suite → Step 5: Commit: `feat(native): buildIndexedEntry — file → full index row (parity)`.

---

### Task 8: SQLite writer (`IndexWriter.swift`)

**Files:** Create `IndexWriter.swift`; Test `IndexWriterTests.swift`.

**Rust to mirror:** schema DDL (:1162-1238), `insert_indexed_entry` (:1263+), entry_text/themes/search/trigram inserts (:1331-1379), `meta` table.

**Swift contract:**
```swift
public enum IndexWriter {
    /// Create the full schema on an open GRDB Database (DROP IF EXISTS then CREATE,
    /// matching indexer.rs exactly incl. the 4 indexes and meta table).
    static func createSchema(_ db: Database) throws
    /// Insert one entry across entries + entry_text + entry_themes + entry_search + entry_trigram.
    static func insert(_ db: Database, _ entry: IndexedEntry) throws
}
```
Match column lists/values exactly (entry_search.title = searchText of the 4 title variants; entry_search.year = fts_json(year_json) flattened to space-separated leaves; entry_search.themes = themes joined " "; entry_trigram.text = the same searchText string stored in entry_text.search_text; entry_themes one row per nonempty theme with the entry type). Port `fts_json` (:1115-1136) for the year column.

- [ ] Step 1: `IndexWriterTests.swift` (failing): open an in-memory/temp GRDB DB, `createSchema`, `insert` a couple of `IndexedEntry`s, then read back via raw SQL AND via `IndexDatabase(indexDBPath:)` (point it at the temp file) — assert `loadEntries()` returns the expected entries and `search()` finds them (incl. a CJK substring hitting `entry_trigram`). Assert `entry_themes` has the right rows.
- [ ] Step 2: FAIL → Step 3: implement → Step 4: PASS + full suite → Step 5: Commit: `feat(native): GRDB index writer (schema + inserts, FTS parity)`.

---

### Task 9: VaultIndexer — full build + incremental reconcile (`VaultIndexer.swift`)

**Files:** Create `VaultIndexer.swift`; Test `VaultIndexerTests.swift`.

**Rust to mirror:** `walk_markdown` (:610-628), `build_sqlite_index` (:247-311) incl. temp-build + atomic rename + WAL flip, `reconcile_index` (:350-425), `upsert_path_in_conn`/`delete_path_rows`, `mtime_ms`, the entries sort order, and the `INDEX_WRITE_LOCK` mutual exclusion.

**Swift contract:**
```swift
public struct ReconcileStats: Sendable, Equatable { public var upserted, removed, unchanged: Int }

public final class VaultIndexer: Sendable {
    public init(workspaceRoot: String)
    /// Full rebuild → temp DB → atomic rename → WAL. Returns count.
    public func buildFull() throws -> Int
    /// Delta: build index if missing/schema-stale; else mtime-diff upsert/delete. Returns stats.
    public func reconcile() throws -> ReconcileStats
}
```
Use GRDB `DatabasePool` (WAL) for the live DB; build the temp DB with a `DatabaseQueue` and `journal_mode=OFF` for bulk speed, then `FileManager.moveItem` over the live path, then open with DatabasePool to ensure WAL. Serialize writes with an internal `NSLock`/actor (the `INDEX_WRITE_LOCK` analogue) so a reconcile and a rename never overlap. `added` set from `gitAddedDates` on full build. Schema-staleness check = presence of REQUIRED columns (title_en,title_cn,publisher,isbn,translation_title_cn,translation_douban_url).

- [ ] Step 1: `VaultIndexerTests.swift` (failing): create a temp workspace with `vault/papers/a.md` + `vault/notes/b.md`; `buildFull()` → assert count==2 and `IndexDatabase` reads them. Then add `vault/papers/c.md`, touch `a.md` (new mtime), delete `b.md`; `reconcile()` → assert stats (upserted incl. c + a, removed b) and the DB reflects it. Assert `.trash`/dotfiles are skipped. Assert a second `reconcile()` with no changes → all `unchanged`.
- [ ] Step 2: FAIL → Step 3: implement (mirror Rust) → Step 4: PASS + full suite → Step 5: Commit: `feat(native): VaultIndexer — full build + mtime-diff reconcile (GRDB single writer)`.

---

### Task 10: Wire into the app + remove the sidecar

**Files:** Modify `apple/Sources/Marple/MarpleApp.swift`; modify `AppModel.swift` if needed; delete `SidecarProcess.swift` + `HTTPVaultClient.swift` (+ their tests `SidecarLaunchTests.swift`, `HTTPVaultClientTests.swift`); modify `apple/Package.swift` only if a target ref breaks.

**Behavior:** On boot, construct `VaultIndexer(workspaceRoot:)`; run `reconcile()` on a background task (so a missing/stale index is built before/while the UI loads); construct `LocalVaultClient` + `AppModel` and `loadIndex()`. Use the existing `VaultWatcher` to fire a debounced `reconcile()` on vault changes, then trigger `AppModel.loadIndex()` (or a lighter refresh) so the list reflects external/edit changes. STOP creating/`start()`ing `SidecarProcess`. Remove the now-dead `SidecarProcess` and `HTTPVaultClient` types and their tests.

- [ ] Step 1: READ the current `MarpleApp.swift` and `AppModel.swift`. Replace the `SidecarProcess`+`start()` flow with: build `VaultIndexer`, kick a background `reconcile()` (catch+log errors), then build `LocalVaultClient`/`AppModel`. Decide the simplest correct ordering so first run (no index) still ends with a populated list (e.g. `try indexer.reconcile()` before `loadIndex()`; show the existing boot spinner meanwhile, and fix its label from "启动 reader-api…" to "建立索引…").
- [ ] Step 2: Wire `VaultWatcher` → on change, `try? indexer.reconcile()` then `await model.loadIndex()` (debounced via the existing Coalescer). Confirm the watcher's existing usage in AppModel and integrate without duplicating reloads.
- [ ] Step 3: Delete `SidecarProcess.swift`, `HTTPVaultClient.swift`, `SidecarLaunchTests.swift`, `HTTPVaultClientTests.swift`. Fix any references (e.g. `VaultConfig.findRepoRoot`/`repoRoot` may now be unused — remove only what's genuinely dead and in files you're already editing).
- [ ] Step 4: `cd apple && swift build` (zero warnings) and `cd apple && swift test` (all green; the deleted sidecar tests are gone).
- [ ] Step 5: Commit (stage the modified + deleted files): `feat(native): in-process VaultIndexer replaces the sidecar; remove SidecarProcess/HTTPVaultClient`.
- [ ] Step 6: GUI verification (HUMAN). Launch against the real vault. Confirm: NO `reader-api` process spawns (`pgrep -fl reader-api` → empty); list populates; first-run builds the index; editing a file updates search after the debounce; create/trash/restore work; no `database is locked`; no SQLITE_CANTOPEN. Report log; treat failures as new debugging tasks.

---

## Self-Review

**Spec coverage:** Every `entries` column + all FTS tables (Tasks 2-4,7,8); type detection & walk (Tasks 2,9); reconcile algorithm + atomic build (Task 9); frontmatter parsing incl. lenient fallback (Task 1); fuzzy PDF + git added (Tasks 5,6); app wiring + sidecar removal (Task 10). ✓

**Placeholder scan:** Each task names the exact Rust function to mirror + concrete parity tests with inputs/expected; the gnarly ports (lenient YAML, fuzzy_pick_source) point at the Rust source to replicate verbatim under test — this is the spec for a port, not a placeholder.

**Type consistency:** `YamlValue` (Task 1) is consumed by Tasks 2-4,7; `IndexedEntry` (Task 7) is produced by `buildIndexedEntry` and consumed by `IndexWriter` (8) and `VaultIndexer` (9); `IndexDatabase` (Phase 1) reads what `IndexWriter` writes — Task 8's test asserts exactly that round-trip. `ReconcileStats` defined in Task 9.

**Parity risks flagged for extra test attention:** frontmatter lenient parse (Task 1), fuzzy PDF (Task 5), git path-format match (Task 6), preview/CJK rules (Task 4), title_cn H1 fallback (Task 3).

## Out of scope
- Phase 3: semantic search (BGE-M3) — separate plan.
- Embeddings/vectors tables (`entry_vectors*`) — the indexer never wrote them on the default path; not ported.
