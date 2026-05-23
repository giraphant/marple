# marple-native — P3b Design (Tabs + history + pin + reorder)

- **Date:** 2026-05-23
- **Status:** Approved → ready for implementation (batch execute, GUI-test at end)
- **Predecessor:** P3 Read context + metadata (`docs/superpowers/2026-05-23-marple-native-p3-handoff.md`, GUI-validated)
- **Parent spec:** `docs/superpowers/specs/2026-05-23-marple-native-reader-design.md` §11 (P3)

## 0. Scope decision

P3 split the originally-bundled "read context + tabs" work and shipped only the
inspector + metadata write-back. **This phase (P3b) completes the deferred
app-shell rework: tabs, per-tab back/forward history, pin, and drag-reorder.**

All new behavior stays inside the existing boundaries: pure navigation logic lands
in `MarpleKit` (swift-testing covered), UI lands in `Marple`, all data still flows
through `VaultClient`. **reader-api is not modified and the web build is not
touched** (carried initiative constraint).

### Non-goals (this phase)

- **Persistence across launches** (restore tabs after relaunch) → that's the
  separate "data freshness" backlog item; not bundled here. Nav types stay pure so
  it's an easy later add, but P3b adds no `@AppStorage`/`SceneStorage`.
- **Per-tab sort/filter/search** — sort/filter remain global app preferences;
  search stays global + transient (cleared on navigation/tab switch).
- **Auto-sorting pinned tabs to the front** — pin is a marker + close-protection,
  not a reorder; tab order is purely user-controlled (drag).
- **Tab overflow UI** (scroll/menu when many tabs) — strip just wraps/clips for now.

## 1. Goals

- **Tabs**: multiple open locations at once; switch between them; one always active.
- **Per-tab back/forward history**: every navigation pushes onto the active tab's
  stack; back/forward retrace it (browser semantics — forward truncated on a new
  push). Drives wikilink/relation jumps and pane switches alike.
- **Pin**: mark a tab important; protects it from `⌘W` close; renders compactly.
- **Drag-reorder**: reorder tabs in the strip.
- Keyboard: `⌘T` new, `⌘W` close, `⌘[`/`⌘]` back/forward, `⌃⇥`/`⌃⇧⇥` next/prev,
  `⌘1…⌘9` select tab — exposed as a discoverable **标签** menu.

## 2. Decisions locked

| Question | Decision |
|---|---|
| What a tab scopes | A full **location = (pane, openPath?)** + its own history + pinned flag. Switching tabs swaps the whole 3-column view state (sidebar highlight, list, detail). |
| What a "location" is | `NavLocation { pane: Pane; openPath: String? }`. Both the middle list (pane) and the detail doc (openPath) restore together. |
| History granularity | One entry per distinct location. `select(pane:)`, `open(path)`, `follow(wikilink)`, relation/theme taps all push. Consecutive duplicates are no-ops. |
| select(pane:) and the open doc | Switching the sidebar pane **keeps** the open doc (matches P2 behavior); only the pane dimension changes in the pushed location. |
| Sort / filter / search | **Global**, not per-tab. Search text is cleared on tab switch and history nav (consistent with `select(pane:)` already clearing it). |
| Last tab | `closeTab` is a **no-op when only one tab remains** (the window never goes tabless; we don't quit). |
| Pin semantics | Visual marker + compact render + **`⌘W` skips a pinned active tab**. Closable only via its `×` / context-menu "关闭标签". No auto-resort. |
| New tab content | Inherits the **current pane**, no open doc (a clean browse of the current category). Appended at the end, activated. |
| Open-in-new-tab | `openInNewTab(path)` appends a tab at the current pane + that doc, activates it. Wired to a list-row context menu ("在新标签页打开"). |
| Tab switch + doc load | On switch/back/forward, if the active location's `openPath` differs from the currently-loaded doc, re-fetch+render it (low-ms at this vault scale); guarded by a `loadedDocPath` so unchanged docs don't reload. |
| Keyboard mechanism | `@FocusedValue(\.appModel)` + `Commands`. **⌘W close-tab** lives in `CommandGroup(replacing: .saveItem)` (removes the system File-close so plain ⌘W hits a tab; 关闭窗口 → ⇧⌘W) — CodeEdit's pattern. The rest live in `CommandMenu("标签")`. |
| Tab strip placement | A full-width horizontal strip **above** the `NavigationSplitView` (browser-like); back/forward + "+" live in the strip. |
| Reorder mechanism | A custom **`DragGesture` "lift and make room"** (CodeEdit-style): the dragged tab follows the cursor via a non-animated offset; only the *other* tabs animate to open a gap; order commits via `Workspace.reorder(_:)` (pure, tested) on release. (A first `.draggable`/`.dropDestination` pass felt poor — no live feedback, raw-UUID drag image — so it was replaced.) |
| Nav type naming | Tab type is `NavTab` (avoid clash with SwiftUI's `Tab`). |

## 3. Architecture

```
RootView (when booted)
┌──────────────────────────────────────────────────────────┐
│ TabStripView   ◀ ▶   [NavTab][NavTab*pinned][NavTab]   +  │  ← active-tab switch, drag-reorder
├──────────────────────────────────────────────────────────┤
│ NavigationSplitView                                        │
│   Sidebar (pane)  │  EntryList / Themes (pane)  │ DocView  │  ← all read active tab's location
└──────────────────────────────────────────────────────────┘
        ▲ reads pane/openPath/tabs (computed off Workspace)
        │ mutations: select / open / follow / goBack / goForward / tab ops
        └──────────────── AppModel ── wraps ──► Workspace (MarpleKit, pure)
                              │  derived caches recomputed off the render path
                              ▼
                         VaultClient (entryText / writeFile / search / index)

TabCommands (CommandMenu "标签") --@FocusedValue(\.appModel)--> AppModel
```

## 4. MarpleKit — `Navigation.swift` (pure, swift-testing)

```swift
public struct NavLocation: Hashable, Sendable {
    public var pane: Pane
    public var openPath: String?
    public init(pane: Pane, openPath: String? = nil)
}

public struct NavHistory: Hashable, Sendable {
    public private(set) var entries: [NavLocation]
    public private(set) var index: Int
    public init(_ initial: NavLocation)
    public var current: NavLocation { entries[index] }
    public var canGoBack: Bool      // index > 0
    public var canGoForward: Bool   // index < entries.count - 1
    public mutating func push(_ loc: NavLocation)   // no-op if == current; truncates forward; appends; advances
    public mutating func back()                     // clamped
    public mutating func forward()                  // clamped
}

public struct NavTab: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var history: NavHistory
    public var pinned: Bool
    public init(id: UUID = UUID(), location: NavLocation, pinned: Bool = false)
    public var location: NavLocation { history.current }
}

public struct Workspace: Sendable {
    public private(set) var tabs: [NavTab]
    public private(set) var activeID: NavTab.ID
    public init(initial: NavLocation)
    public var activeTab: NavTab { tabs.first { $0.id == activeID } ?? tabs[0] }

    // navigation on the active tab
    public mutating func navigateActive(to: NavLocation)   // push on active
    public mutating func backActive()
    public mutating func forwardActive()

    // tab ops
    @discardableResult public mutating func newTab(_ loc: NavLocation, activate: Bool = true) -> NavTab.ID  // append (+activate)
    public mutating func closeTab(_ id: NavTab.ID)   // remove; if it was active, activate min(i, last); never empties (caller guards last-tab)
    public mutating func select(_ id: NavTab.ID)
    public mutating func selectIndex(_ idx: Int)     // clamp/ignore out of range
    public mutating func selectRelative(_ delta: Int) // wraps for ⌃⇥ / ⌃⇧⇥
    public mutating func togglePin(_ id: NavTab.ID)
    public mutating func reorder(_ ids: [NavTab.ID])  // drag result; no-op unless ids is a permutation
}
```

Invariants the tests pin down:
- A fresh `Workspace` has exactly one tab, active.
- `navigateActive` only mutates the active tab's history; other tabs untouched.
- `push` of the current location is a no-op (no duplicate history entries).
- `push` after a `back()` truncates the forward entries (browser semantics).
- `closeTab` of the active tab activates the right neighbor (`min(removedIndex, count-1)`).
- `move` is a stable reorder; `move` of a tab onto itself is a no-op.
- `selectIndex` out of range is ignored; `selectRelative` wraps.

`Workspace` is **not** `@Observable` — it's a value held by `AppModel`; mutating it
writes the stored property, which `@Observable AppModel` tracks.

## 5. AppModel (Marple) — refactor onto Workspace

- Replace stored `pane` / `openPath` with `private(set) var workspace: Workspace`.
  Expose **computed** read-only conveniences (so existing view reads compile
  unchanged and `@Observable` tracks them via `workspace`):
  ```swift
  var pane: Pane          { workspace.activeTab.location.pane }
  var openPath: String?   { workspace.activeTab.location.openPath }
  var tabs: [NavTab]      { workspace.tabs }
  var activeTabID: NavTab.ID { workspace.activeID }
  var canGoBack: Bool     { workspace.activeTab.history.canGoBack }
  var canGoForward: Bool  { workspace.activeTab.history.canGoForward }
  ```
- Track `private var loadedDocPath: String?` (the doc whose body/blocks/caches are
  currently in `openBlocks`/`openBody`/`openEntry`/…), so tab/history switches only
  re-fetch when the doc actually changes.
- **Navigation intents** (all push history on the active tab, then sync):
  - `select(pane:)` → `navigateActive(.init(pane: newPane, openPath: openPath))`;
    clear search; `recomputeVisible()` (doc unchanged → no reload).
  - `open(path)` → `navigateActive(.init(pane: pane, openPath: path))`; `await
    loadDoc(path)` (always loads — also serves `reloadOpen`).
  - `follow(target)` → resolve → `open(resolved)`.
  - `goBack()` / `goForward()` → `workspace.backActive()/forwardActive()`; `await
    syncToActiveLocation()`.
- **Tab intents:** `newTab()`, `closeTab(_:)`, `closeActiveTab()` (no-op on last
  tab; skips a pinned active tab), `selectTab(_:)`, `selectTab(index:)`,
  `selectNextTab()`, `selectPrevTab()`, `togglePin(_:)`, `moveTab(id:before:)`,
  `openInNewTab(_:)`. Active-changing ones call `await syncToActiveLocation()`.
- Helpers:
  ```swift
  private func loadDoc(_ path: String?) async      // fetch+split+blocks+recomputeOpenDerived; sets loadedDocPath; path==nil clears
  private func syncToActiveLocation() async         // clear search; recomputeVisible(); if openPath != loadedDocPath { await loadDoc(openPath) }
  func tabTitle(_ tab: NavTab) -> String            // doc → entry.title ?? filename; pane → type.label / "#theme" / "主题"
  func tabIsDoc(_ tab: NavTab) -> Bool              // location.openPath != nil
  ```
- Metadata write-back (`applyPatch`, `setRating` … `removeTheme`) is unchanged — it
  reads `openPath` (now computed) and still re-derives caches.
- `reloadOpen()` (FSEvents) unchanged in spirit: `if let p = openPath { await open(p) }`
  → still only refreshes the open doc (the index-refresh gap stays a backlog item).

## 6. UI (Marple)

- **`RootView.swift`** — replaces the inline `NavigationSplitView` in `MarpleApp`:
  ```
  VStack(spacing: 0) { TabStripView(model:); Divider(); NavigationSplitView { … } }
    .focusedSceneValue(\.appModel, model)
  ```
- **`TabStripView.swift`** — horizontal strip:
  - Left: `◀` back (`model.goBack`, disabled `!canGoBack`), `▶` forward.
  - Middle: fixed-width `TabChip`s (title + small doc/list icon, pin icon if pinned,
    `×` close; pinned = compact). Active chip highlighted. A select Button →
    `selectTab(id)`. `.contextMenu` → 固定/取消固定, 关闭, 关闭其他. Reorder via a
    `DragGesture` (lift-and-make-room) committing `setTabOrder(ids)` on release.
  - Right: `+` new tab.
  - Pinned chips render compact (icon only, no title, no `×`).
- **`TabCommands.swift`** — `FocusedValues.appModel` key + a `Commands` struct with
  `CommandMenu("标签")`: 新建标签 `⌘T`, 关闭标签 `⌘W`, 后退 `⌘[`, 前进 `⌘]`,
  下一个标签 `⌃⇥`, 上一个标签 `⌃⇧⇥`, and 选择标签 1–9 `⌘1…⌘9`. Each item
  `@FocusedValue(\.appModel)`-guarded (disabled when nil / not applicable).
- **`MarpleApp.swift`** — `body` shows `RootView(model:)` when booted; `.commands { TabCommands() }`.
- **`EntryRow` / `EntryListView`** — add a row `.contextMenu` "在新标签页打开" →
  `model.openInNewTab(entry.path)`.
- Unchanged: `SidebarView`, `DocView`, `InspectorView`, `ThemesView` keep reading
  `model.pane` / `model.openPath` (now computed) and calling `model.select` /
  `model.open` (now history-pushing). `DocView`'s toolbar (external editor +
  inspector toggle) stays.

## 7. Data flow

- **tab switch / back / forward:** mutate `Workspace` → computed `pane`/`openPath`
  change → `syncToActiveLocation()` recomputes the list and, if the doc changed,
  reloads it. Sidebar highlight + list + detail all follow.
- **navigation within a tab** (sidebar/list/wikilink/relation): pushes a location;
  forward history truncated.
- **new tab / open-in-new-tab:** appends + activates; sync loads its doc (or clears).

## 8. Testing

- **NavHistory** — initial flags; push advances + sets current; push==current no-op;
  push truncates forward after back; back/forward clamp at ends.
- **Workspace** — single initial active tab; `navigateActive` isolated to active
  tab; `newTab` appends+activates and leaves others' history intact; `closeTab`
  active→correct neighbor, inactive→active preserved; `select`/`selectIndex`
  (in/out of range)/`selectRelative` wrap; `togglePin`; `reorder` permutation +
  no-op on incomplete/unknown input.
- **NavTab** — `location` reflects `history.current` after pushes/back.
- **Regression** — the existing 84 MarpleKit tests stay green (Browse `Pane` reused
  unchanged).
- **Manual GUI (end of phase):** new tab (`⌘T` + `+`); switch tabs (click, `⌘1-9`,
  `⌃⇥`); list/wikilink/relation navigation pushes history; `◀`/`▶` + `⌘[`/`⌘]`
  retrace and restore both list + doc; pin marks + compact + `⌘W` skips it; `×`/
  context-menu close; can't close the last tab; drag-reorder; "在新标签页打开";
  P1/P2/P3 regression (browse speed, wikilinks, inspector, metadata writes).

## 9. Risks

- **Reactivity through a value-type `Workspace`** — `@Observable` tracks the stored
  `workspace` property, so any `mutating` call invalidates dependent views; computed
  `pane`/`openPath` re-read it. Mitigation: all mutations go through `AppModel`
  methods that assign `workspace` (no escaping the model's observation).
- **`@FocusedValue` timing** — the value is set on `RootView` (only present once
  booted), so `标签` menu items are correctly disabled pre-boot. If a shortcut
  proves dead, fall back to strip buttons with `.keyboardShortcut`.
- **`⌘W` vs window-close** — RESOLVED: the standard File-close group is replaced
  (`CommandGroup(replacing: .saveItem)`) so plain ⌘W reaches our 关闭标签; 关闭窗口
  moved to ⇧⌘W. GUI-validated.
- **Drag-reorder feel** — RESOLVED: the `.draggable`/`.dropDestination` pass felt
  poor (no live feedback, raw-UUID drag image); replaced with the CodeEdit-style
  `DragGesture` lift-and-make-room (dragged tab glued to cursor, others animate a
  gap). GUI-validated.
- **Doc reload on every switch** — acceptable at this vault scale; `loadedDocPath`
  guard avoids redundant reloads. Per-tab block caching is a later perf item.
