# marple-native — Session Handoff / Work Log (P2 Browse)

**Date:** 2026-05-23 · **Branch:** `main` · **Predecessor:** P1 handoff
(`docs/superpowers/2026-05-23-marple-native-p1-handoff.md`) ·
**Plan:** `docs/superpowers/plans/2026-05-23-marple-native-p2-browse.md`

This log lets a fresh session continue without re-reading the prior conversation.

## What shipped in P2 ("Browse")

The P1 single-论文 list became a **typed three-column browser**:

```
NavigationSplitView:  Sidebar (6 types + 主题)  |  EntryListView  |  DocView
```

- **Typed 6-category sidebar** (`SidebarView.swift`): 物件 section lists the six
  modeled types (论文/图书/作者/主题/章节/笔记) with live counts; 视图 section has a
  主题 entry with a distinct-theme count. Selection drives `AppModel.pane`.
- **Entry list column** (`EntryListView.swift` + `EntryRow.swift`): a header with
  a **search box**, a **sort menu** (single field × asc/desc; the underlying
  engine is multi-clause), and a **filter menu** (评分 ≥ N, 仅含 PDF) over a native
  `List` of type-aware rows (title / author / year / ★rating / PDF badge).
- **Lexical search**: typing calls `VaultClient.search` (debounced 200ms) →
  `GET /api/search?mode=fast&entry_type=<current type>`; results replace the list.
  Fast/lexical mode only — **balanced/deep deferred to P5**.
- **主题 cross-cut** (`ThemesView.swift`): selecting 主题 shows an adaptive grid of
  themes (count desc, name asc); tapping one sets `pane = .theme(name)` and the
  list shows entries of **any** type carrying that theme.

## Architecture (what changed)

**MarpleKit (pure, swift-testing-covered):**
- `Entry.swift` — now decodes `mtime/added/source/book/topic/doi`; `EntryType` is
  `Hashable` with `EntryType.modeled` (canonical order) + `.label` (中文).
- `ListSort.swift` — `SortField/SortDir/SortClause` + `sortEntries(_:by:)`:
  multi-level **stable** sort, empties always last regardless of direction
  (ports `src/list-sort.ts` `sortEntriesMulti`).
- `ListFilter.swift` — `FilterField/Op/Match/Clause` + `applyFilters(_:_:match:now:)`:
  flat AND/OR clauses, incomplete clauses ignored (`now` is injectable for
  deterministic tests) (ports `src/list-filter.ts`).
- `ThemeIndex.swift` — `themeCounts(_:) -> [ThemeCount]` (count desc, name asc).
- `Browse.swift` — `Pane` enum (`.type/.theme/.themesIndex`) + `entriesForPane`.
- `VaultClient.swift` — `SearchQuery` + `SearchHit` DTOs + `search(_:)` on the
  protocol; `StubVaultClient` returns seeded hits.
- `HTTPVaultClient.swift` — `search(_:)` builds `/api/search` query, decodes hits.

**Marple app (build + manual GUI):**
- `AppModel.swift` — generalized from `papers` to `pane / counts / themeIndex /
  sortClauses / filterClauses / filterMatch / searchText / searchHits` with a
  computed `visibleEntries` (search hits when searching, else
  pane subset → filter → sort). `runSearch()` is debounced + cancellable.
- `SidebarView.swift`, `EntryRow.swift`, `EntryListView.swift`, `ThemesView.swift`,
  `MarpleApp.swift` (three-column layout switching on the pane).

Boundary discipline held: UI depends only on `VaultClient` + DTOs; only
`HTTPVaultClient` knows the wire.

## Verification (2026-05-23)

- `swift build` — **clean** (MarpleKit + Marple app).
- `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
  — **50 tests in 14 suites, all pass** (P1's 28 + new ListSort/ListFilter/
  ThemeIndex/Browse/Entry-browse-fields/search tests).
- App boots: sidecar comes up, `[marple] index loaded: 15142 entries`.
- Live-API data path checked via curl on the boot port:
  counts per type (chapter-summary 11573, paper-analysis 2198, book-overview
  1047, author-profile 307, note 8, topic-synthesis 8, topic-reading-list 1),
  and `fast` search scoped to a type returns ranked hits.
- **GUI eyeball pass — DONE.** User confirmed 2026-05-23: "看着没啥问题，基本功能都
  出来了" (looks fine, basic functions all present). Checklist below for regressions.

### GUI checklist (run `swift run Marple`, drive, tail `/tmp/marple-app.log`)

- sidebar shows 6 types with the counts above + 主题 with a count;
- clicking each type switches the middle list + updates its title/count;
- sort 评分↓ floats rated entries up, blanks last; 仅含 PDF + 评分≥3 shrink the list;
- typing in search returns ranked hits (`[marple] search … -> N hits`);
- 主题 → grid → click a theme → cross-type filtered list;
- selecting an entry still opens the reader; wikilinks + 用外部编辑器打开 still work
  (P1 regression check).

Stop a run: `pkill -f "debug/Marple"; pkill -f "release/reader-api"`.

## Known limitations / deferred

- **Search modes:** only `fast` (lexical/metadata). Balanced (full-text) + deep
  (vector/semantic) → P5.
- **Filter UI** ships 评分≥ + 仅含 PDF only; the ported `ListFilter` engine is fully
  general (year/author/theme/source/added) for a richer builder later.
- **Presentation** is a native `List`, not a card grid (kept for virtualization /
  scroll feel — the #1 motivation); card grid is a later visual-polish item.
- The lone `topic-reading-list` entry (`.other`) is not reachable from the typed
  sidebar (only via 主题 if it carries themes). Acceptable — 6 types are modeled.
- Carried from P1: hardcoded `repoRoot`/`vaultDir` in `MarpleApp.swift`; the
  `NSTableView` "reentrant operation" warning (still a warning).

## Next: P3 — Read context + metadata

Per spec §11: right panel (目录 / 信息 / 统计), `PropertyPanel` metadata write-back
(`writeFrontmatter`), tabs + back/forward history + pin + reorder. Start with
brainstorming → writing-plans → subagent/inline execution as in P1/P2.
