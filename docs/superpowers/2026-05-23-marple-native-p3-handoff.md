# marple-native — Session Handoff / Work Log (P3 Read context + metadata)

**Date:** 2026-05-23 · **Branch:** `main` · **Predecessor:** P2 Browse
(`docs/superpowers/2026-05-23-marple-native-p2-handoff.md`) ·
**Spec:** `docs/superpowers/specs/2026-05-23-marple-native-p3-design.md` ·
**Plan:** `docs/superpowers/plans/2026-05-23-marple-native-p3.md`

This log lets a fresh session continue without re-reading the prior conversation.

## Scope shipped in P3

Per the spec's scope decision, P3 covered **two of the three** originally-bundled
pieces: the **right inspector panel** and **metadata write-back**. Tabs +
back/forward history + pin + reorder were **deferred to P3b** (not started).

```
DocView (detail)  ──.inspector()──►  InspectorView
  ScrollViewReader, heading blocks .id            single scroll panel:
  onChange(scrollTarget) → scrollTo                 [icon strip → jump to section]
                                                    统计 (DocStats)
                                                    信息 (edit + relations)
                                                    目录 (tap → scrollTarget)
```

- **Right inspector** (`InspectorView.swift`), Ulysses-style: one scrollable panel
  with a top icon strip (统计 / 信息 / 目录) that jumps to a section. Hosted via the
  native `.inspector()` modifier with a toolbar toggle (default visible).
  - **统计** — `字符 / 字 / 段落 / 阅读时间` from a CJK-aware `DocStats`.
  - **目录** — heading outline derived from the parsed blocks; tapping scrolls the
    reading view (`ScrollViewReader` + block `.id`, via `model.scrollTarget`).
  - **信息** — editable metadata + read-only relations.
- **Metadata write-back** — the app's **first writes to disk**. Editable:
  **rating / year / source / topic / doi** (scalars) **+ themes** (flow array).
  **Author is read-only** this phase (shown + linked to its author-profile) — see
  "author wart" below. Writes go through a **surgical line-level patch** (only the
  touched line changes) → `PUT /vault/*path`. reader-api unchanged; web build
  untouched.

## Architecture (what changed)

**MarpleKit (pure, swift-testing-covered):**
- `DocStats.swift` — `computeDocStats(_:) -> DocStats{chars,charsNoSpace,words,
  paragraphs,minutes}`; CJK ideograph = 1 word, Latin/digit run = 1, reading time
  `max(1, round(words/300))`. Port of `src/doc-stats.ts`.
- `DocOutline.swift` — `outline(from:[RenderBlock]) -> [OutlineItem{blockIndex,
  level,text}]` from `.heading` blocks; `tokensText(_:)` flattens inline tokens
  (wikilink → label). `blockIndex` is the scroll target / `id`.
- `FrontmatterPatch.swift` — `setScalar(_:key:value:numeric:)` and
  `setThemes(_:_:)`. Operates only between the `---` fences; body returned
  verbatim. Update-in-place / insert-before-close / clear-removes-line; quotes a
  scalar only when YAML needs it; `numeric: true` keeps number fields (year) bare;
  themes always flow `[a, b, c]` (fixes the malformed `themes: []()` seen in vault).
- `RelationsIndex.swift` — `splitAuthors(_:)` (separators `,` / ` & ` / ` and `,
  matching `src/wiki.ts`), `buildAuthorIndex` / `buildAnnotationIndex`, and
  `relations(for:in:authorIndex:annotationIndex:) -> Relations{works, siblings,
  similar, annotations, authorProfile}`. Port of the `PropertyPanel` backlinks memo.
- `Entry.swift` — decodes `annotates`; adds a `with(...)` copy helper (double-
  optional params: `.some(nil)` clears, omit keeps).
- `VaultClient.swift` — protocol gains `writeFile(path:text:)`; `StubVaultClient`
  records the last write via a `WriteLog` box. `HTTPVaultClient.writeFile` → `PUT`.

**Marple app:**
- `AppModel.swift` — new caches `openEntry / openBody / openOutline / openStats /
  openRelations` (recomputed in `open()` / reload via `recomputeOpenDerived()`),
  index-level `authorIndex / annotationIndex` (built in `rebuildIndexDerived()`),
  a `scrollTarget` channel, and `savingField / writeError`. Write intents
  `setRating / setYear / setSource / setTopic / setDoi / addThemes / removeTheme`
  all run **fetch-fresh → patch → PUT → apply-on-success** via `applyPatch(...)`;
  on failure nothing local changes and `writeError` surfaces.
- `InspectorView.swift` — the panel + section/row components (RatingRow star
  picker, ScalarRow text field commit-on-submit, ThemesEditor chips in an adaptive
  grid, AuthorRow read-only link, RelationsView grouped tappable rows).
- `DocView.swift` — `ScrollViewReader` + heading `.id` + `onChange(scrollTarget)`;
  `.inspector(isPresented:)` hosting `InspectorView`; toolbar toggle. Empty-state
  label changed 论文→文档.

Boundary discipline held: UI depends only on `VaultClient` + DTOs; only
`HTTPVaultClient` knows the wire.

## The author wart (why author is read-only)

The indexer reads `author = field("author") OR field("authors")`. Vault files store
`authors: [array]`; the web app, when editing author, writes a **new singular
`author:` key and leaves `authors:` stale** — it only "works" via read precedence.
Under a clean-diff mandate P3 does **not** replicate that, so author editing is
deferred. Proper author editing (rewrite the real `authors:` array, split the
joined string) is a later item.

## Verification (2026-05-23)

- `swift build` — **clean** (MarpleKit + Marple app).
- `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
  — **84 tests in 19 suites, all pass** (P2's 50 + DocStats / DocOutline /
  FrontmatterPatch{Scalar,Themes} / RelationsIndex / Entry-annotates / writeFile).
- App boots on the real vault: `[marple] index loaded: 15142 entries`, no
  errors/panics (boot now also builds author/annotation indexes over 15k entries).
- **GUI eyeball pass — PENDING (handoff to user).** Checklist below.

### GUI checklist (run `swift run Marple`, drive, tail `/tmp/marple-app.log`)

- Inspector toggles via the toolbar button (右上 `sidebar.trailing`); default
  visible with a doc open.
- Icon strip jumps to 统计 / 信息 / 目录.
- 统计 shows 字符/字/段落/阅读时间 for the open doc.
- 目录 lists headings; clicking one scrolls the reading view to it.
- 信息: edit 评分 (★), 年份, 来源, 专题, DOI; add/remove a 主题 → on-disk frontmatter
  changes; `git diff <file>` shows a **single clean changed line**; sidebar
  rating/theme filters + counts reflect the change. A failed write shows
  「保存失败：…」 inline and changes nothing.
- 关系: 作者作品 / 同作者 / 同主题相似 / 我的批注 + 作者档案 link navigate.
- Regression: wikilinks still navigate, 用外部编辑器打开 works, type switching is
  still fast (P1/P2).

Stop a run: `pkill -f "debug/Marple"; pkill -f "release/reader-api"`.

## Known limitations / deferred

- **Tabs / history / pin / reorder** → P3b (not started).
- **Author editing** → later (see wart above); read-only for now.
- **Citation copy / 阅读原文·译本 / full bibliographic rows** → later (out of P3
  per spec).
- **Scroll-spy** (active-heading highlight) deferred; outline is click-to-scroll.
- Theme chips use an adaptive `LazyVGrid`, not a true flow layout — fine for now.
- Carried from P1/P2: hardcoded `repoRoot`/`vaultDir` in `MarpleApp.swift`; the
  `NSTableView` "reentrant operation" warning (still a warning).

## Next: P3b — Tabs + history

Heterogeneous tabs (list/doc/themes), per-tab back/forward history, pin,
drag-reorder. `AppModel` currently has a single `openPath`; tabs means an array of
tab states each with its own history stack. Start with brainstorming →
writing-plans → execution as in P1/P2/P3.
