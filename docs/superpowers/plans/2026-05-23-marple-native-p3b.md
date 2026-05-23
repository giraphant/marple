# marple-native — P3b Implementation Plan (Tabs + history + pin + reorder)

- **Spec:** `docs/superpowers/specs/2026-05-23-marple-native-p3b-design.md`
- **Branch:** `main` (no worktree, per initiative convention)
- **Test cmd:** `swift test --package-path apple -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
- **Baseline:** 84 tests / 19 suites green.

## Step 1 — MarpleKit Navigation core (TDD)

1. Write `Tests/MarpleKitTests/NavigationTests.swift` (red): NavHistory
   (push/back/forward/truncate/no-op), Workspace (newTab/closeTab/select/
   selectIndex/selectRelative/togglePin/move/navigateActive), NavTab.location.
2. Add `Sources/MarpleKit/Navigation.swift`: `NavLocation`, `NavHistory`, `NavTab`,
   `Workspace` per spec §4. Make tests green.
3. Full suite green (84 + new).

## Step 2 — AppModel refactor onto Workspace

1. Replace stored `pane`/`openPath` with `private(set) var workspace` + computed
   `pane`/`openPath`/`tabs`/`activeTabID`/`canGoBack`/`canGoForward`.
2. Add `loadedDocPath`; split `open()` into `open(path)` (navigate + always
   `loadDoc`) and `loadDoc(_:)`; add `syncToActiveLocation()`.
3. Rewrite `select(pane:)` to push a location; `follow` → `open`. Add `goBack/
   goForward`, tab ops (`newTab/closeTab/closeActiveTab/selectTab/selectTab(index:)/
   selectNextTab/selectPrevTab/togglePin/moveTab/openInNewTab`), `tabTitle/tabIsDoc`.
4. Keep `applyPatch` + write intents + `reloadOpen` working against computed
   `openPath`. `swift build` clean.

## Step 3 — UI: tab strip + commands

1. `RootView.swift`: `VStack { TabStripView; Divider; NavigationSplitView{…} }` +
   `.focusedSceneValue(\.appModel, model)`. Move the split view out of `MarpleApp`.
2. `TabStripView.swift`: back/forward, tab chips (title+icon, pin marker, ×, active
   highlight), context menu, `.draggable`/`.dropDestination` reorder, `+`.
3. `TabCommands.swift`: `FocusedValues.appModel` key + `CommandMenu("标签")` with
   ⌘T/⌘W/⌘[/⌘]/⌃⇥/⌃⇧⇥/⌘1-9.
4. `MarpleApp.swift`: render `RootView` when booted; `.commands { TabCommands() }`.
5. `EntryRow`/`EntryListView`: row context menu "在新标签页打开".
6. `swift build` clean.

## Step 4 — Verify + handoff

1. Full `swift test` green; `swift build` clean.
2. Boot on the real vault (`swift run Marple > /tmp/marple-app.log` — confirm index
   loads, no panics; I drive it minimally, real GUI eyeballing is the user's).
3. Update memory (P3b status). Write
   `docs/superpowers/2026-05-23-marple-native-p3b-handoff.md` with GUI checklist.
4. Commit authored files only (apple/** + the three P3b docs); leave the user's
   web edits (`index.html`, `src/**`, `src-tauri/**`) untouched. Do not push.
5. Hand off the GUI checklist to the user.
