# marple-native — P3 Design (Read context + metadata)

- **Date:** 2026-05-23
- **Status:** Approved (brainstorming) → ready for implementation plan
- **Predecessor:** P2 Browse (`docs/superpowers/2026-05-23-marple-native-p2-handoff.md`)
- **Parent spec:** `docs/superpowers/specs/2026-05-23-marple-native-reader-design.md` §11 (P3)

## 0. Scope decision

The reader-design spec's P3 bundled three independent subsystems: the right panel,
metadata write-back, and a tabs/history/pin/reorder app-shell rework. **This phase
covers the first two only — the right panel and metadata write-back.** Tabs +
back/forward history + pin + reorder are deferred to a later sub-phase (P3b).

All new behavior stays inside the existing boundaries: pure logic lands in
`MarpleKit` (swift-testing covered), UI lands in `Marple`, and all data in/out
goes through `VaultClient`. **reader-api is not modified and the web build is not
touched** (carried constraint from the initiative).

## 1. Goals

- A right-side **inspector panel** over the reading view, modeled on the Ulysses
  inspector the user pointed to: a single scrollable panel with a top icon strip
  and stacked sections **统计 / 信息 / 目录**.
- **统计** — document stats (字符 / 字 / 段落 / 阅读时间).
- **目录** — heading outline; clicking a heading scrolls the reading view to it.
- **信息** — editable metadata (the app's **first writes to disk**) plus read-only
  knowledge relations.
- Metadata write-back via a **surgical line-level frontmatter patch** that changes
  only the touched line, keeping git diffs clean (git is the backup/undo layer).

### Non-goals (this phase)

- No tabs / history / pin / reorder (→ P3b).
- No scroll-spy (active-heading highlight while scrolling) — click-to-scroll only.
- No author editing (read-only this phase — see §5).
- No citation copy / 阅读原文·译本 actions, no full bibliographic rows (→ later).
- No new reader-api endpoint; writes reuse the existing `PUT /vault/*path`.

## 2. Decisions locked during brainstorming

| Question | Decision |
|---|---|
| Phase scope | Right panel + metadata write-back; tabs/history deferred |
| Write-back strategy | Surgical line-level patch in Swift (no YAML lib, no backend change) |
| Right-panel structure | Ulysses-style single scrollable inspector; icon strip jumps to a section |
| 信息 scope | Editable attributes + themes + read-only relations (no citation/biblio) |
| 目录 interaction | Click-to-scroll only (`ScrollViewReader`); no scroll-spy |
| Inspector mechanism | Native SwiftUI `.inspector()` (free trailing panel + toggle) |
| Outline source | Derive from parsed `[RenderBlock]` `.heading` cases, not a line scan |
| Write path | Re-fetch fresh → patch → PUT → apply-on-success; error banner on failure |
| Editable fields | rating / year / source / topic / doi (scalars) + themes (flow array) |

## 3. Architecture

```
DocView (detail)                    .inspector(isPresented:)
  ScrollView + ScrollViewReader   ───────────────►  InspectorView
    heading blocks carry .id                          ScrollView + ScrollViewReader
    onChange(model.scrollTarget) → scrollTo            icon strip → jump to section
                                                       ┌ StatsSection   (DocStats)
                                                       ├ InfoSection    (edit + relations)
                                                       └ OutlineSection (→ scrollTarget)
        ▲                                                     │ writes
        │ reads (open / reloadOpen)                           ▼ intents
        └──────────────── AppModel ──────────────────────────┘
                              │  (all caches recomputed off the render path)
                              ▼
                         VaultClient
                   entryText (fetch) · writeFile (PUT /vault/*path)
```

## 4. MarpleKit (pure logic, swift-testing)

### `DocStats.swift`
Port of `src/doc-stats.ts`.
```
public struct DocStats: Equatable, Sendable {
  let chars, charsNoSpace, words, paragraphs, minutes: Int
}
public func computeDocStats(_ body: String) -> DocStats
```
- CJK-aware `words`: each CJK ideograph = 1, each Latin/digit run = 1.
- `paragraphs`: split on blank-line runs, trim, drop empties.
- `minutes`: `words>0 ? max(1, round(words/300)) : 0`.
- Tests port the Vitest cases in `src/doc-stats.test.ts`.

### `DocOutline.swift`
```
public struct OutlineItem: Equatable, Sendable, Identifiable {
  let blockIndex: Int     // index into the rendered [RenderBlock]; scroll target + id
  let level: Int          // 1–6
  let text: String
}
public func outline(from blocks: [RenderBlock]) -> [OutlineItem]
```
- Walks `blocks`, emits one item per `.heading(level, tokens)`, `text` = visible
  inline text of the tokens, `blockIndex` = position in the array.
- Code blocks are already separate `RenderBlock`s, so a `#` inside code can't be
  mistaken for a heading (the fence problem `doc-outline.ts` guards is moot here).

### `FrontmatterPatch.swift` (core new unit — heavily TDD'd)
Operates only on the region between the opening and closing `---` fences; the body
is returned byte-for-byte unchanged. Reuses `Frontmatter.split` semantics.
```
public enum FrontmatterPatch {
  // Update the line for `key` in place; insert before the closing fence if absent;
  // remove the line if `value == nil`. Quotes/escapes the value when needed.
  public static func setScalar(_ raw: String, key: String, value: String?) -> String
  // Rewrite (or insert) `themes:` as a flow array; [] → "themes: []".
  public static func setThemes(_ raw: String, _ themes: [String]) -> String
}
```
Rules:
- **Quoting** (`setScalar`): emit a double-quoted, escaped value when the string
  is empty, contains `: ` or `#` or `:` at end, has leading/trailing space, starts
  with a YAML indicator (`[{>|*&!%@\`"'`-? ), or parses as a bool/null/number but
  is meant as text. Otherwise emit the plain value. (rating writes `★`-strings,
  always plain; year writes a bare integer.)
- **Insert** appends `key: value` on its own line immediately before the closing
  `---` (key order otherwise preserved; only one line added).
- **Clear** (`value == nil`) removes the whole `key:` line.
- **Themes**: replace the existing `themes:` line(s) — including the malformed
  `themes: []()` seen in the vault — with a single `themes: [a, b, c]` flow line;
  insert if absent; `[]` when empty. Theme strings are quoted by the same rule.
- Idempotence: patching with the current value yields identical text.
- The closing-fence search matches `Frontmatter.split` (`^\s*---\s*$` after line 0).

### `RelationsIndex.swift`
Port of the `PropertyPanel` backlinks `useMemo`.
```
public func splitAuthors(_ s: String?) -> [String]          // port of wiki.ts splitAuthors
public struct Relations: Equatable, Sendable {
  var works: [Entry]          // author-profile: all works by this author
  var siblings: [Entry]       // paper/book: other works by the same author(s)
  var similar: [Entry]        // same-type entries sharing ≥2 themes (cap 6)
  var annotations: [Entry]    // notes whose `annotates` == this path
  var authorProfile: Entry?   // paper/book: the matching author-profile entry
}
public func buildAuthorIndex(_ entries: [Entry]) -> [String: [Entry]]   // lowercased name
public func buildAnnotationIndex(_ entries: [Entry]) -> [String: [Entry]] // keyed by target path
public func relations(for: Entry, in: [Entry],
                      authorIndex: [String:[Entry]],
                      annotationIndex: [String:[Entry]]) -> Relations
```
- All lists sort by `ratingScore` desc (matches the web).
- Author-profile keyed off `title` (the index maps `name`→title for authors).

### `Entry.swift`
Add `public let annotates: String?` decoded from `annotates` (already in the index
JSON). Needed by `buildAnnotationIndex` / `批注于`.

## 5. Editable fields & the author wart

The indexer reads `author = field("author") OR field("authors")`. Vault files store
`authors: [array]`; the web app, when editing author, writes a **new singular
`author:` key and leaves the `authors:` array stale** — it only "works" because of
read precedence. Under a clean-diff mandate we will **not** replicate that. So:

- **Editable (file key == logical field, clean one-line patch):**
  `rating` (★-string), `year` (bare int), `source`, `topic`, `doi`, `themes` (flow).
- **Read-only this phase:** `author` — shown as text + a link to its author-profile
  (via `Relations.authorProfile`), but not editable. Proper author editing
  (updating the real `authors:` array, splitting the joined string) is a later item.

Field visibility per type mirrors `FIELDS_BY_TYPE` in `PropertyPanel.tsx`
(e.g. note edits nothing; author-profile edits only rating; topic-synthesis edits
rating + topic). Author rows render as read-only where present.

## 6. VaultClient

```
protocol VaultClient {            // additions
  func writeFile(path: String, text: String) async throws
}
```
- `HTTPVaultClient.writeFile` → `PUT {base}/{path}` (path already includes the
  `vault/...` prefix, same string-concat rule as `get`), body = full file text,
  `Content-Type: text/markdown; charset=utf-8`; non-2xx → `VaultError.http`.
- `StubVaultClient` records the last `(path, text)` write for assertions.
- `entryText(path:)` (existing) is the fetch-fresh read used before each patch.

## 7. AppModel

New state (all derived caches recomputed off the render path, per the P2 perf
discipline):
- Open doc: `openEntry: Entry?`, `openBody: String`, and caches
  `openOutline: [OutlineItem]`, `openStats: DocStats?`, `openRelations: Relations?`,
  recomputed in `open()` and `reloadOpen()`.
- Index-level: `authorIndex`, `annotationIndex`, built in `rebuildIndexDerived()`.
- `scrollTarget: Int?` — set by an outline tap, observed by `DocView`.
- `savingField: String?` and `writeError: String?` — drive the info section's
  saving/disabled state and inline error.

Write intents (one per field; each is fetch-fresh → patch → PUT → apply-on-success):
```
func setRating(_ stars: Int?)        // nil clears
func setYear(_ text: String?)
func setSource(_ text: String?)
func setTopic(_ text: String?)
func setDoi(_ text: String?)
func addThemes(_ raw: String)        // comma-split, dedupe
func removeTheme(_ theme: String)
```
Each:
1. `let raw = try await client.entryText(path: openPath)`
2. patch via `FrontmatterPatch`
3. `try await client.writeFile(path:, text:)`
4. on success: replace the matching `Entry` in `entries` with a field-updated copy,
   then `rebuildIndexDerived()` (themes/rating affect themeIndex/filters) +
   `recomputeVisible()` + refresh `openEntry`/`openRelations`.
5. on failure: set `writeError`; leave state unchanged.

Apply-on-success (not optimistic-then-revert): on localhost the round-trip is
instant, and this avoids revert bookkeeping while keeping the vault the source of
truth. A brief `savingField` disables the row mid-write.

## 8. UI (Marple)

- **`InspectorView.swift`** — `ScrollViewReader { ScrollView { … } }`:
  - Top **icon strip** (3 buttons: 统计 chart / 信息 list / 目录 outline) → `proxy.scrollTo(sectionAnchor)`.
  - `StatsSection`: 字符 / 字 / 段落 / 阅读时间 rows from `openStats`.
  - `InfoSection`: `RatingRow` (★ picker), `ScalarRow` (TextField, commit on
    Enter/blur, Esc cancels), `ThemesEditor` (chips with remove + add field),
    read-only author row, and relations groups (`同作者`, `同主题相似`, `我的批注`,
    author-profile link) rendered as tappable `MiniRow`s that call `model.open`.
    Disabled + dimmed while `savingField != nil`; `writeError` shows inline.
  - `OutlineSection`: heading rows indented by `level`; tap sets `model.scrollTarget`.
- **`DocView.swift`** — wrap content in `ScrollViewReader`; give each heading block
  `.id(blockIndex)`; `.onChange(of: model.scrollTarget)` → `withAnimation { proxy.scrollTo(target, anchor: .top) }`; attach
  `.inspector(isPresented: $inspectorShown) { InspectorView(model:) }` with a
  toolbar toggle; inspector defaults visible when a doc is open.
- Components mirror `PropertyPanel.tsx` behavior natively (no web styling).

## 9. Data flow

- **open(path):** fetch text → `Frontmatter.split` → `MarkdownModel.blocks` →
  compute `openOutline` (from blocks), `openStats` (from body), look up `openEntry`,
  compute `openRelations`. All cached on the model.
- **edit:** intent → fetch-fresh → patch → PUT → update entry + caches (§7).
- **outline tap:** sets `scrollTarget` → `DocView` scrolls.
- **external save:** FSEvents → `reloadOpen()` reuses the same recompute path.

## 10. Error handling

- Writes: failure sets `writeError` shown inline in the info section; no local
  mutation applied. Reads unchanged from P1/P2.
- `VaultError` cases reused; PUT non-2xx → `.http(status, body)`.

## 11. Testing

- **DocStats** — port `doc-stats.test.ts` (CJK counting, paragraphs, minutes edges).
- **DocOutline** — headings extracted with right levels; non-heading blocks ignored.
- **FrontmatterPatch** (focus) — update in place; insert when absent; clear removes
  line; quoting (colon/`#`/leading-indicator/CJK/numeric-as-text); flow themes;
  fix malformed `themes: []()`; body untouched; idempotence.
- **RelationsIndex** — `splitAuthors`; works/siblings/similar(≥2 themes, cap 6)/
  annotations; rating-desc ordering.
- **HTTPVaultClient.writeFile** — `URLProtocol` mock asserts PUT method, URL, body.
- **Entry** — `annotates` decodes.
- **Manual GUI (end of phase):** inspector toggle; three sections + icon jump; edit
  rating/themes/year → on-disk frontmatter changes by a single clean line (verify
  `git diff`); outline tap scrolls; relations links navigate; P1/P2 regression
  (wikilinks, 用外部编辑器打开, type switching).

## 12. Risks

- **Surgical quoting fidelity** — the main risk; mitigated by porting real vault
  frontmatter shapes into the `FrontmatterPatch` test suite and erring toward
  quoting when ambiguous.
- **Cross-view scroll coordination** — `scrollTarget` + `ScrollViewReader` is the
  simplest reliable channel; if `.id`/`scrollTo` proves flaky on long docs, fall
  back to an explicit anchor map.
- **`.inspector()` availability** — requires macOS 14+; this Mac/runtime is current,
  so acceptable.
