# marple-native — Browse-State Persistence + First-Run Vault Picker (handoff)

**Date:** 2026-05-23
**Plan:** `docs/superpowers/plans/2026-05-23-marple-native-persistence-and-vault-picker.md`
**Status:** IMPLEMENTED, `swift build` clean, **137 swift-testing tests in 28 suites pass** (prior 120 + 17 new). NOT yet GUI-validated. Committed to `main` (NOT pushed).

## Why this, and why now (the coupling decision)

Picked from the [[native-study-backlog]] usability/correctness set. The user flagged the watcher-index-refresh as possibly entangled with the future sidecar→pure-Swift migration. It is: the sidecar runs its **own** file watcher (`reader-api` `start_vault_watcher` + `notify-debouncer-mini`) that reconciles its SQLite index, so a Swift watcher that re-fetched `/api/index` on every FS event would (a) race the sidecar's re-index and (b) be a coarse full-refetch that gets replaced by an incremental in-memory diff once the index lives in-process. **So the watcher-index-refresh was deferred to ride the migration**, where it becomes clean. The two items shipped here have **zero** sidecar coupling and are not rework: persistence is pure UI/state storage; the vault picker actually *helps* the migration (the pure-Swift impl needs the same path resolution).

## What shipped

### 1. Browse-state persistence (remember your place across launches)
- **MarpleKit `PersistedState`** (`PersistedState.swift`): Codable snapshot = per-tab `{location, pinned}` + `activeIndex` + `sortClauses` + `filterClauses` + `filterMatch` + `browseMode` (raw string, so MarpleKit stays agnostic of the app's `BrowseMode` enum). `makeWorkspace()` rebuilds a `Workspace`.
- **`StateStore` protocol + `UserDefaultsStateStore`** (JSON blob under `marple.persistedState`). `@unchecked Sendable` because `UserDefaults` isn't `Sendable` (it's thread-safe in practice).
- **Codable** added to `Pane`, `SortField/SortDir/SortClause`, `FilterField/FilterOp/FilterMatch/FilterClause`, `NavLocation` (`Pane` auto-synthesizes since `EntryType` is already Codable).
- **`Workspace` restore + prune** (`Navigation.swift`): `init?(restoring:activeIndex:)` (clamps active index, nil on empty), `pruneOpenPaths(validPaths:)` + `NavHistory.replaceCurrent`.
- **AppModel wiring**: `init(client:stateStore:)` restores on launch; **persistence is automatic via `didSet { persist() }`** on the five state-bearing properties (`workspace`, `sortClauses`, `filterClauses`, `filterMatch`, `browseMode`) — no per-intent hooks, can't-miss. After `loadIndex`, stale open paths are pruned and the restored active doc is loaded. `browseMode` stays a plain `var` so `RootView`'s `$model.browseMode` binding is unchanged.

### 2. First-run vault picker (no more hardcoded paths)
- **MarpleKit `resolveVaultPaths(repoRoot:)`** (`VaultConfig.swift`): reads `repoRoot/marple.config.json` → `workspaceRoot` → derives `vaultDir = workspaceRoot/vault`; throws `VaultPathsError.missingConfig` / `.badConfig`.
- **`SetupView`** (new): folder picker (`NSOpenPanel`, dirs only) that validates the choice and surfaces a friendly error for a wrong folder.
- **`MarpleApp` rewired**: `@AppStorage("marple.repoRoot")`; when empty/unresolvable → `SetupView`, else boot from resolved paths. `SidecarProcess` is now constructed lazily inside `AppState.boot(paths:)` (was eager in init with the hardcoded `repoRoot`). The two hardcoded `static let repoRoot/vaultDir` are gone.

## New/changed files
- New: `MarpleKit/PersistedState.swift`, `MarpleKit/VaultConfig.swift`, `Marple/SetupView.swift`
- New tests: `MarpleKitTests/PersistedStateTests.swift` (Codable + Workspace restore + PersistedState/StateStore), `MarpleKitTests/VaultConfigTests.swift`
- Modified: `MarpleKit/{Browse,ListSort,ListFilter,Navigation}.swift`, `Marple/{AppModel,MarpleApp}.swift`

## GUI test checklist (please run)
1. **First run:** launch shows `SetupView` → pick the marple repo folder (`/Users/ramudai/Documents/Learn/marple`) → boots. Picking a non-repo folder shows the inline error.
2. **Restore place:** open a doc, switch panes, set a sort + a filter, toggle list↔grid, open 2–3 tabs (pin one) → **quit and relaunch** → tabs, active tab, open doc, pane, sort/filter, grid/list all come back.
3. **Stale path:** with a doc open in a tab, delete that file externally, relaunch → that tab opens with no doc (no "load failed" wall).
4. **Reset:** `defaults delete Marple marple.repoRoot` (or wherever `@AppStorage` lands for the `swift run` binary) → relaunch → `SetupView` again.

Live-tail logs while testing: `cd apple && swift run Marple > /tmp/marple-app.log 2>&1`

## Deferred (unchanged)
- **Watcher → index refresh** rides the sidecar migration (see above + [[sidecar-migration]]). Today the Swift watcher still only reloads the open doc.
- Masonry polish (theme chips on card, hover/selection, Table view-mode) — [[native-study-backlog]].
