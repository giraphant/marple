# marple-native — Session Handoff / Work Log (P3b Tabs + history)

**Date:** 2026-05-23 · **Branch:** `main` · **Predecessor:** P3 Read context + metadata
(`docs/superpowers/2026-05-23-marple-native-p3-handoff.md`, GUI-validated) ·
**Spec:** `docs/superpowers/specs/2026-05-23-marple-native-p3b-design.md` ·
**Plan:** `docs/superpowers/plans/2026-05-23-marple-native-p3b.md`

This log lets a fresh session continue without re-reading the prior conversation.

## Scope shipped in P3b

The app-shell rework deferred from P3: **tabs + per-tab back/forward history + pin +
drag-reorder**, plus the `标签` keyboard-command menu. reader-api unchanged; web
build untouched.

```
RootView
┌──────────────────────────────────────────────────────────┐
│ TabStripView  ◀ ▶  [tab][tab*pin][tab]                +  │  switch / drag-reorder / close
├──────────────────────────────────────────────────────────┤
│ NavigationSplitView                                        │
│   Sidebar(pane) │ EntryList/Themes(pane) │ DocView         │  all read the active tab's location
└──────────────────────────────────────────────────────────┘
        AppModel  ── wraps ──►  Workspace (MarpleKit, pure)
TabCommands(CommandMenu "标签") --@FocusedValue(\.appModel)--> AppModel
```

A **tab** = a full location `(pane, openPath?)` + its own history stack + a pinned
flag. Switching tabs swaps the whole 3-column view state. Every navigation (sidebar
pane, list open, wikilink follow, relation/theme tap) pushes a history entry on the
active tab; `◀`/`▶` retrace it (forward truncated on a new push, browser-style).

## Architecture (what changed)

**MarpleKit — new `Navigation.swift` (pure, swift-testing covered):**
- `NavLocation { pane: Pane; openPath: String? }` — restorable place; both columns
  restore together.
- `NavHistory` — `entries: [NavLocation]` + `index`; `push` (no-op if == current;
  truncates forward; appends; advances), `back`/`forward` (clamped), `canGoBack/
  Forward`, `current`.
- `NavTab: Identifiable` — `id: UUID`, `history`, `pinned`; `location ==
  history.current`. Named `NavTab` (not `Tab`) to avoid clashing with SwiftUI's `Tab`.
- `Workspace` — `tabs: [NavTab]` + `activeID`; `navigateActive(to:)`/`backActive`/
  `forwardActive` (active tab only), `newTab`/`closeTab` (neighbor `min(i,last)`)/
  `select`/`selectIndex`/`selectRelative` (wraps)/`togglePin`/`move(id:before:)`.
  Pure value type — `AppModel` holds one; `@Observable` tracks the stored property.

**Marple app:**
- `AppModel.swift` — replaced stored `pane`/`openPath` with `private(set) var
  workspace`; `pane`/`openPath`/`tabs`/`activeTabID`/`canGoBack`/`canGoForward` are
  now **computed** off the active tab (existing view reads compile unchanged). Added
  `loadedDocPath` guard, `loadDoc(_:)` (fetch/split/blocks/derive; `nil` clears) +
  `syncToActiveLocation()` (clear search → recomputeVisible → reload doc only if it
  changed). `open()` = navigate + `loadDoc`; `select(pane:)` pushes a location
  keeping the open doc; `follow` → `open`. New intents: `goBack/goForward`, `newTab`,
  `openInNewTab`, `selectTab(_:)`/`selectTab(index:)`/`selectNextTab`/`selectPrevTab`,
  `closeTab`/`closeActiveTab` (skips pinned, no-op on last)/`closeOtherTabs`,
  `togglePin`, `moveTab`, plus `tabTitle`/`tabIsDoc` for the strip. Metadata
  write-back + `reloadOpen` (now `loadDoc`) still work against computed `openPath`.
- `RootView.swift` — `VStack { TabStripView; Divider; NavigationSplitView{…} }` +
  `.focusedSceneValue(\.appModel, model)`. (Moved the split view out of `MarpleApp`.)
- `TabStripView.swift` — `◀`/`▶` (disabled at ends), a horizontal scroll of chips,
  `+`. Each chip: a select Button (icon + title; pinned = icon-only compact) + `×`
  (disabled when last), active highlight, `.help`, `.draggable(id.uuidString)` +
  `.dropDestination(for: String.self)` → `moveTab`, and a context menu (固定/取消固定,
  关闭标签, 关闭其他标签).
- `TabCommands.swift` — classic `FocusedValueKey` (the `@Entry` macro needs a newer
  SDK than these Command Line Tools) + `CommandMenu("标签")`: 新建标签 ⌘T, 关闭标签
  ⌘W, 后退 ⌘[, 前进 ⌘], 下一个/上一个标签 ⌃⇥ / ⌃⇧⇥, 选择标签 1–9 ⌘1…⌘9.
- `MarpleApp.swift` — booted branch shows `RootView(model:)`; scene `.commands {
  TabCommands() }`.
- `EntryListView.swift` — list-row context menu "在新标签页打开" → `openInNewTab`.

Boundary discipline held: pure nav logic in MarpleKit; UI depends only on
`AppModel` + `VaultClient`; only `HTTPVaultClient` knows the wire.

## Decisions (and what was deferred)

- **Location = (pane, openPath)**; switching a tab restores both list + detail.
- **select(pane:) keeps the open doc** (matches P2); only the pane changes.
- **Sort/filter/search are global**, not per-tab; search clears on nav/tab switch.
- **Can't close the last tab** (no-op); the window never goes tabless.
- **Pin** = compact render + `⌘W` protection + closable only via ×/context menu;
  **not** auto-sorted to the front (keeps drag-reorder unambiguous).
- **New tab** inherits the current pane, no doc. **Open-in-new-tab** = current pane +
  that doc, activated.
- **Persistence across launches is NOT in P3b** — that's the separate "data
  freshness" backlog item. Nav types are pure so it's an easy later add.
- **Doc reload on tab/history switch** re-fetches when the doc changes (low-ms at
  this scale; `loadedDocPath` skips no-op reloads). Per-tab block caching = later perf.

## Verification (2026-05-23)

- `swift build` — **clean** (MarpleKit + Marple app).
- `swift test --package-path apple -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
  — **104 tests in 21 suites, all pass** (P3's 84 + 20 new: `NavHistoryTests` +
  `WorkspaceTests`).
- App boots on the real vault: `[marple] index loaded: 15142 entries`, sidecar up,
  no panics. Only warning is the carried `NSTableView` "reentrant operation" warning.
- **GUI eyeball pass — PENDING (handoff to user).** Checklist below.

### GUI checklist (run `swift run Marple > /tmp/marple-app.log 2>&1`, drive, tail the log)

- **New tab:** `⌘T` and the `+` button each open a tab on the current category, no doc.
- **Switch:** click a chip; `⌘1`…`⌘9` jump to the Nth tab; `⌃⇥` / `⌃⇧⇥` cycle
  next/prev (wraps). Sidebar highlight + list + detail all follow the active tab.
- **History:** open a doc → click a wikilink → click a relation; `◀` (and `⌘[`)
  retraces doc→doc and restores the list/pane; `▶` (`⌘]`) re-advances. A new
  navigation after going back drops the old forward entries. Switching the sidebar
  pane is also a history step (back returns to the previous pane, doc kept).
- **Pin:** context-menu 固定标签 → chip goes compact (icon only) with a pin dot; `⌘W`
  no longer closes it; ×/context-menu 关闭标签 still does.
- **Close:** `×` and 关闭标签 close; can't close the **last** tab (no-op). 关闭其他标签
  keeps the clicked tab + pinned ones.
- **Drag-reorder:** drag a chip left/right; order persists for the session.
- **Open-in-new-tab:** right-click a list row → 在新标签页打开 opens + activates a new tab.
- **⚠ Verify specifically:** `⌘W` closes a *tab* (not the window) while a tab
  remains — if it closes the window instead, the `标签` menu item lost to the
  standard Close (fallback: rebind close-tab to `⌘⇧W`). Also sanity-check the
  horizontal drag-reorder feel inside the scrollable strip.
- **Regression:** wikilinks navigate; inspector (统计/信息/目录) + metadata writes
  (★/主题/年份…) still work; 用外部编辑器打开 works; type switching still fast (P1/P2);
  external save (FSEvents) still refreshes the open doc.

Stop a run: `pkill -f "release/Marple"; pkill -f "debug/Marple"; pkill -f "release/reader-api"`.

## Known limitations / deferred

- **Tab persistence across launches** → "data freshness" backlog item (with the
  watcher-refreshes-index + browse-state-restore work). Not in P3b.
- **Watcher still only reloads the open doc**, not the index (carried backlog gap).
- **No per-tab block cache** — doc re-fetched on switch (fine at current scale).
- **No tab-overflow chrome** — the strip just scrolls horizontally when full.
- Carried: hardcoded `repoRoot`/`vaultDir` in `MarpleApp.swift`; `NSTableView`
  reentrant-operation warning; author editing read-only (P3 wart).

## Next candidates

- **Data freshness** (the deferred backlog): watcher refreshes the whole index on
  external add/delete/edit + persist tabs/browse-state across launches.
- **Sidecar migration** (deferred by user this round): in-process Swift + SQLite
  FTS5 (trigram) for browse/read + fast search; semantic search later.
- **P3 leftovers:** author editing, citation copy / 阅读原文·译本, scroll-spy.
