# Browse-State Persistence + First-Run Vault Picker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the native app remember your place across launches (tabs + pane + sort/filter + list/grid mode) and replace the hardcoded repo/vault paths with a one-folder first-run picker — both with zero coupling to the sidecar, so neither item is rework when the sidecar→pure-Swift migration happens later.

**Architecture:**
- **Persistence:** A pure, `Codable` `PersistedState` snapshot in MarpleKit (each tab's current location + pinned, the active-tab index, plus sort/filter/filterMatch and the browse-mode string). `AppModel` restores it on init and re-saves automatically via `didSet { persist() }` on the five state-bearing properties — no per-intent hooks. Backend is a `StateStore` protocol (UserDefaults-backed in the app, in-memory-substitutable in tests).
- **Vault picker:** A pure `resolveVaultPaths(repoRoot:)` in MarpleKit reads `repoRoot/marple.config.json` → `workspaceRoot` → derives `vaultDir = workspaceRoot/vault`. The app stores the chosen `repoRoot` in `@AppStorage`; when absent/invalid it shows a `SetupView` folder picker; otherwise it boots from the resolved paths.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, swift-testing (`import Testing`), SPM two-target layout (`MarpleKit` lib + `Marple` executable). Tests run with the CommandLineTools framework search path (no full Xcode).

**Test command (memory: this Mac has CLT, not Xcode):**
```
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```
**Build command:** `cd apple && swift build`

---

## File Structure

**MarpleKit (pure, TDD-tested):**
- Modify `apple/Sources/MarpleKit/Browse.swift` — `Pane: Codable`.
- Modify `apple/Sources/MarpleKit/ListSort.swift` — `SortField/SortDir/SortClause: Codable`.
- Modify `apple/Sources/MarpleKit/ListFilter.swift` — `FilterField/FilterOp/FilterMatch/FilterClause: Codable`.
- Modify `apple/Sources/MarpleKit/Navigation.swift` — `NavLocation: Codable`; `NavHistory.replaceCurrent`; `Workspace.init?(restoring:activeIndex:)`; `Workspace.pruneOpenPaths`.
- Create `apple/Sources/MarpleKit/PersistedState.swift` — `PersistedTab`, `PersistedState`, `StateStore`, `UserDefaultsStateStore`.
- Create `apple/Sources/MarpleKit/VaultConfig.swift` — `MarpleConfig`, `VaultPaths`, `VaultPathsError`, `resolveVaultPaths`.

**Marple (app target, build-verified only — no unit tests, matching the existing AppModel boundary):**
- Modify `apple/Sources/Marple/AppModel.swift` — `stateStore` injection, restore in init, `didSet` persistence, `persist()`, prune+load in `loadIndex`.
- Create `apple/Sources/Marple/SetupView.swift` — first-run folder picker.
- Modify `apple/Sources/Marple/MarpleApp.swift` — `@AppStorage` repoRoot, setup-vs-boot flow, lazy `SidecarProcess`.

**Tests:**
- Create `apple/Tests/MarpleKitTests/PersistedStateTests.swift`
- Create `apple/Tests/MarpleKitTests/VaultConfigTests.swift`
- (Codable round-trips for domain types go in `PersistedStateTests.swift`.)

---

## Task 1: Make domain types Codable

**Files:**
- Modify: `apple/Sources/MarpleKit/Browse.swift:3`
- Modify: `apple/Sources/MarpleKit/ListSort.swift:3,21,23`
- Modify: `apple/Sources/MarpleKit/ListFilter.swift:3,29,30,32`
- Modify: `apple/Sources/MarpleKit/Navigation.swift:6`
- Test: `apple/Tests/MarpleKitTests/PersistedStateTests.swift`

- [ ] **Step 1: Write the failing test** (create the file)

```swift
import Testing
import Foundation
@testable import MarpleKit

@Suite struct DomainCodableTests {
    @Test func paneRoundTrips() throws {
        let cases: [Pane] = [.type(.paperAnalysis), .type(.other("weird")),
                             .themesIndex, .theme("现象学"), .trash]
        for p in cases {
            let data = try JSONEncoder().encode(p)
            #expect(try JSONDecoder().decode(Pane.self, from: data) == p)
        }
    }

    @Test func sortAndFilterClausesRoundTrip() throws {
        let sorts = [SortClause(field: .rating, dir: .desc), SortClause(field: .title, dir: .asc)]
        let filters = [FilterClause(id: "a", field: .year, op: .gte, value: "2000"),
                       FilterClause(id: "b", field: .haspdf, op: .yes, value: "")]
        let sd = try JSONEncoder().encode(sorts)
        let fd = try JSONEncoder().encode(filters)
        #expect(try JSONDecoder().decode([SortClause].self, from: sd) == sorts)
        #expect(try JSONDecoder().decode([FilterClause].self, from: fd) == filters)
        #expect(try JSONDecoder().decode(FilterMatch.self,
                from: JSONEncoder().encode(FilterMatch.any)) == .any)
    }

    @Test func navLocationRoundTrips() throws {
        let loc = NavLocation(pane: .theme("X"), openPath: "vault/a.md")
        let data = try JSONEncoder().encode(loc)
        #expect(try JSONDecoder().decode(NavLocation.self, from: data) == loc)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (types not Codable)

Run the test command above, filtered if desired. Expected: compile error "does not conform to Codable" / cannot encode `Pane`.

- [ ] **Step 3: Add Codable conformances**

`Browse.swift:3` → `public enum Pane: Hashable, Sendable, Codable {`
`ListSort.swift`:
- `:3` → `public enum SortField: String, Sendable, CaseIterable, Hashable, Codable {`
- `:21` → `public enum SortDir: String, Sendable, Hashable, Codable { case asc, desc }`
- `:23` → `public struct SortClause: Sendable, Equatable, Hashable, Codable {`
`ListFilter.swift`:
- `:3` → `public enum FilterField: String, Sendable, CaseIterable, Hashable, Codable {`
- `:29` → `public enum FilterOp: String, Sendable, Hashable, Codable { case gte, lte, eq, contains, is_ = "is", yes, within }`
- `:30` → `public enum FilterMatch: String, Sendable, Hashable, Codable { case all, any }`
- `:32` → `public struct FilterClause: Sendable, Equatable, Hashable, Identifiable, Codable {`
`Navigation.swift:6` → `public struct NavLocation: Hashable, Sendable, Codable {`

(`EntryType` is already `Codable`, so `Pane`'s auto-synthesized enum Codable resolves.)

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Browse.swift apple/Sources/MarpleKit/ListSort.swift apple/Sources/MarpleKit/ListFilter.swift apple/Sources/MarpleKit/Navigation.swift apple/Tests/MarpleKitTests/PersistedStateTests.swift
git commit -m "feat(native): Codable conformances for browse/nav domain types"
```

---

## Task 2: Workspace restore + prune primitives

**Files:**
- Modify: `apple/Sources/MarpleKit/Navigation.swift` (add to `NavHistory` and `Workspace`)
- Test: `apple/Tests/MarpleKitTests/PersistedStateTests.swift` (append a suite)

- [ ] **Step 1: Write the failing tests** (append to the test file)

```swift
@Suite struct WorkspaceRestoreTests {
    @Test func restoringBuildsTabsAndActive() throws {
        let ws = try #require(Workspace(restoring: [
            (NavLocation(pane: .type(.paperAnalysis)), false),
            (NavLocation(pane: .theme("X"), openPath: "v/a.md"), true),
        ], activeIndex: 1))
        #expect(ws.tabs.count == 2)
        #expect(ws.tabs[1].pinned)
        #expect(ws.activeTab.location.openPath == "v/a.md")
    }

    @Test func restoringEmptyReturnsNil() {
        #expect(Workspace(restoring: [], activeIndex: 0) == nil)
    }

    @Test func restoringClampsActiveIndex() throws {
        let ws = try #require(Workspace(restoring: [
            (NavLocation(pane: .trash), false),
        ], activeIndex: 9))
        #expect(ws.activeTab.location.pane == .trash)
    }

    @Test func pruneNullsMissingOpenPaths() throws {
        var ws = try #require(Workspace(restoring: [
            (NavLocation(pane: .type(.book), openPath: "gone.md"), false),
            (NavLocation(pane: .type(.book), openPath: "keep.md"), false),
        ], activeIndex: 0))
        ws.pruneOpenPaths(validPaths: ["keep.md"])
        #expect(ws.tabs[0].location.openPath == nil)
        #expect(ws.tabs[1].location.openPath == "keep.md")
    }

    @Test func replaceCurrentSwapsActiveEntry() {
        var h = NavHistory(NavLocation(pane: .trash, openPath: "x"))
        h.replaceCurrent(with: NavLocation(pane: .trash, openPath: nil))
        #expect(h.current.openPath == nil)
    }
}
```

(`Workspace` must be `Equatable` for `== nil`; it currently is not — but `Optional<Workspace> == nil` only needs the optional comparison, which does **not** require `Workspace: Equatable`. `#expect(opt == nil)` compiles for any wrapped type.)

- [ ] **Step 2: Run — expect FAIL** (`restoring:` init / `pruneOpenPaths` / `replaceCurrent` undefined)

- [ ] **Step 3: Implement** — add to `Navigation.swift`

Into `NavHistory` (after `forward()`):
```swift
    public mutating func replaceCurrent(with loc: NavLocation) { entries[index] = loc }
```

Into `Workspace` (after `init(initial:)`):
```swift
    /// Rebuild a workspace from persisted tab snapshots. Each tab starts with a
    /// fresh single-entry history at its saved location. Returns nil if empty.
    public init?(restoring tabs: [(location: NavLocation, pinned: Bool)], activeIndex: Int) {
        guard !tabs.isEmpty else { return nil }
        let built = tabs.map { NavTab(location: $0.location, pinned: $0.pinned) }
        self.tabs = built
        let idx = built.indices.contains(activeIndex) ? activeIndex : 0
        self.activeID = built[idx].id
    }
```

Into `Workspace` (after `reorder`):
```swift
    /// Null out the current open path of any tab whose open file is no longer in
    /// the index (e.g. deleted/moved between launches). Pane is preserved.
    public mutating func pruneOpenPaths(validPaths: Set<String>) {
        for i in tabs.indices {
            let loc = tabs[i].history.current
            if let p = loc.openPath, !validPaths.contains(p) {
                tabs[i].history.replaceCurrent(with: NavLocation(pane: loc.pane, openPath: nil))
            }
        }
    }
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Navigation.swift apple/Tests/MarpleKitTests/PersistedStateTests.swift
git commit -m "feat(native): Workspace restore + open-path prune primitives"
```

---

## Task 3: PersistedState model + StateStore

**Files:**
- Create: `apple/Sources/MarpleKit/PersistedState.swift`
- Test: `apple/Tests/MarpleKitTests/PersistedStateTests.swift` (append a suite)

- [ ] **Step 1: Write the failing tests** (append)

```swift
@Suite struct PersistedStateTests {
    private func sample() -> PersistedState {
        PersistedState(
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paperAnalysis)), pinned: false),
                   PersistedTab(location: NavLocation(pane: .theme("X"), openPath: "v/a.md"), pinned: true)],
            activeIndex: 1,
            sortClauses: [SortClause(field: .rating, dir: .desc)],
            filterClauses: [FilterClause(id: "a", field: .year, op: .gte, value: "2000")],
            filterMatch: .any,
            browseMode: "list")
    }

    @Test func roundTripsThroughJSON() throws {
        let s = sample()
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(PersistedState.self, from: data) == s)
    }

    @Test func makeWorkspaceRebuildsActiveAndPinned() throws {
        let ws = try #require(sample().makeWorkspace())
        #expect(ws.tabs.count == 2)
        #expect(ws.activeTab.location.openPath == "v/a.md")
        #expect(ws.tabs[1].pinned)
    }

    @Test func userDefaultsStoreRoundTrips() throws {
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        #expect(store.load() == nil)
        store.save(sample())
        #expect(store.load() == sample())
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`PersistedState`/`PersistedTab`/`UserDefaultsStateStore` undefined)

- [ ] **Step 3: Implement** — create `PersistedState.swift`

```swift
import Foundation

/// One restored tab: its current location plus pinned flag. Histories are not
/// persisted — a restored tab starts with a fresh single-entry history.
public struct PersistedTab: Codable, Sendable, Equatable {
    public var location: NavLocation
    public var pinned: Bool
    public init(location: NavLocation, pinned: Bool) {
        self.location = location; self.pinned = pinned
    }
}

/// A launch-to-launch snapshot of the user's place: open tabs + the active one,
/// plus the global browse controls. `browseMode` is a raw string so MarpleKit
/// stays agnostic of the app target's `BrowseMode` enum.
public struct PersistedState: Codable, Sendable, Equatable {
    public var tabs: [PersistedTab]
    public var activeIndex: Int
    public var sortClauses: [SortClause]
    public var filterClauses: [FilterClause]
    public var filterMatch: FilterMatch
    public var browseMode: String

    public init(tabs: [PersistedTab], activeIndex: Int, sortClauses: [SortClause],
                filterClauses: [FilterClause], filterMatch: FilterMatch, browseMode: String) {
        self.tabs = tabs; self.activeIndex = activeIndex
        self.sortClauses = sortClauses; self.filterClauses = filterClauses
        self.filterMatch = filterMatch; self.browseMode = browseMode
    }

    public func makeWorkspace() -> Workspace? {
        Workspace(restoring: tabs.map { (location: $0.location, pinned: $0.pinned) },
                  activeIndex: activeIndex)
    }
}

/// Where persisted state lives. App uses UserDefaults; tests can substitute.
public protocol StateStore: Sendable {
    func load() -> PersistedState?
    func save(_ state: PersistedState)
}

public struct UserDefaultsStateStore: StateStore {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "marple.persistedState") {
        self.defaults = defaults; self.key = key
    }
    public func load() -> PersistedState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }
    public func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/PersistedState.swift apple/Tests/MarpleKitTests/PersistedStateTests.swift
git commit -m "feat(native): PersistedState snapshot + UserDefaults StateStore"
```

---

## Task 4: Wire persistence into AppModel

**Files:**
- Modify: `apple/Sources/Marple/AppModel.swift` (init, the five state props, `loadIndex`)

No unit test (app-target type, matching the existing no-AppModelTests boundary); verified by `swift build` + later GUI test.

- [ ] **Step 1: Add the store + restore in init**

Replace the property + init region. `browseMode` (`:15`), `workspace` (`:19`), and the browse-state block (`:33-35`) gain `didSet { persist() }`; add a `stateStore` field; rewrite `init`.

```swift
    var browseMode: BrowseMode = .grid { didSet { persist() } }

    private(set) var workspace = Workspace(initial: NavLocation(pane: .type(.paperAnalysis))) {
        didSet { persist() }
    }
```
```swift
    private(set) var sortClauses: [SortClause] = [] { didSet { persist() } }
    private(set) var filterClauses: [FilterClause] = [] { didSet { persist() } }
    private(set) var filterMatch: FilterMatch = .all { didSet { persist() } }
```
```swift
    private let stateStore: StateStore?

    init(client: VaultClient, stateStore: StateStore? = nil) {
        self.client = client
        self.stateStore = stateStore
        if let s = stateStore?.load(), let ws = s.makeWorkspace() {
            workspace = ws
            sortClauses = s.sortClauses
            filterClauses = s.filterClauses
            filterMatch = s.filterMatch
            browseMode = BrowseMode(rawValue: s.browseMode) ?? .grid
        }
    }
```

- [ ] **Step 2: Add `persist()`** (place near the derived-recompute section)

```swift
    /// Save the current place (tabs + browse controls). Cheap — a small JSON blob
    /// to UserDefaults; invoked from the state properties' didSet.
    private func persist() {
        guard let stateStore else { return }
        let idx = workspace.tabs.firstIndex { $0.id == workspace.activeID } ?? 0
        stateStore.save(PersistedState(
            tabs: workspace.tabs.map { PersistedTab(location: $0.location, pinned: $0.pinned) },
            activeIndex: idx,
            sortClauses: sortClauses,
            filterClauses: filterClauses,
            filterMatch: filterMatch,
            browseMode: browseMode.rawValue))
    }
```

- [ ] **Step 3: Prune + load restored doc at the end of `loadIndex`**

In `loadIndex()` (`:126`), after `rebuildIndexDerived(); recomputeVisible()` and before `await loadTrash()`:
```swift
            let valid = Set(entries.map(\.path))
            workspace.pruneOpenPaths(validPaths: valid)
            if openPath != loadedDocPath { await loadDoc(openPath) }
```

- [ ] **Step 4: Build**

Run: `cd apple && swift build`
Expected: builds clean. (`MarpleApp.swift:21` still calls `AppModel(client:)` — fine, `stateStore` defaults to nil; updated in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/Marple/AppModel.swift
git commit -m "feat(native): restore + auto-persist browse state in AppModel"
```

---

## Task 5: Vault path resolver

**Files:**
- Create: `apple/Sources/MarpleKit/VaultConfig.swift`
- Test: `apple/Tests/MarpleKitTests/VaultConfigTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import MarpleKit

@Suite struct VaultConfigTests {
    private func tempRepo(_ json: String?) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marple-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let json {
            try json.write(to: dir.appendingPathComponent("marple.config.json"),
                           atomically: true, encoding: .utf8)
        }
        return dir.path
    }

    @Test func resolvesWorkspaceAndVault() throws {
        let repo = try tempRepo(#"{"workspaceRoot": "/ws/root"}"#)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let paths = try resolveVaultPaths(repoRoot: repo)
        #expect(paths.workspaceRoot == "/ws/root")
        #expect(paths.vaultDir == "/ws/root/vault")
        #expect(paths.repoRoot == repo)
    }

    @Test func missingConfigThrows() throws {
        let repo = try tempRepo(nil)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(throws: VaultPathsError.self) { try resolveVaultPaths(repoRoot: repo) }
    }

    @Test func badJSONThrows() throws {
        let repo = try tempRepo("not json")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(throws: VaultPathsError.self) { try resolveVaultPaths(repoRoot: repo) }
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`resolveVaultPaths`/`VaultPaths`/`VaultPathsError` undefined)

- [ ] **Step 3: Implement** — create `VaultConfig.swift`

```swift
import Foundation

/// The on-disk repo config the sidecar also reads (MARPLE_ROOT/marple.config.json).
public struct MarpleConfig: Codable, Sendable, Equatable {
    public let workspaceRoot: String
}

public struct VaultPaths: Sendable, Equatable {
    public let repoRoot: String
    public let workspaceRoot: String
    public let vaultDir: String
}

public enum VaultPathsError: Error, Equatable {
    case missingConfig(String)
    case badConfig(String)
}

/// Resolve a chosen repo directory into the paths the app needs: `repoRoot` drives
/// the sidecar launch, `vaultDir` (= workspaceRoot/vault) is what the watcher tails.
/// Reads `repoRoot/marple.config.json` for `workspaceRoot`.
public func resolveVaultPaths(repoRoot: String,
                              fileManager: FileManager = .default) throws -> VaultPaths {
    let configPath = (repoRoot as NSString).appendingPathComponent("marple.config.json")
    guard fileManager.fileExists(atPath: configPath) else {
        throw VaultPathsError.missingConfig(configPath)
    }
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: configPath)) }
    catch { throw VaultPathsError.badConfig("\(error)") }
    let cfg: MarpleConfig
    do { cfg = try JSONDecoder().decode(MarpleConfig.self, from: data) }
    catch { throw VaultPathsError.badConfig("\(error)") }
    let vault = (cfg.workspaceRoot as NSString).appendingPathComponent("vault")
    return VaultPaths(repoRoot: repoRoot, workspaceRoot: cfg.workspaceRoot, vaultDir: vault)
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/VaultConfig.swift apple/Tests/MarpleKitTests/VaultConfigTests.swift
git commit -m "feat(native): resolveVaultPaths from marple.config.json"
```

---

## Task 6: First-run picker + app rewiring

**Files:**
- Create: `apple/Sources/Marple/SetupView.swift`
- Modify: `apple/Sources/Marple/MarpleApp.swift`

Build-verified only.

- [ ] **Step 1: Create `SetupView.swift`**

```swift
import SwiftUI
import AppKit
import MarpleKit

/// Shown when no valid repo root is configured. Picks a folder, validates it has a
/// readable marple.config.json, and hands the path up to be persisted + booted.
struct SetupView: View {
    var onPicked: (String) -> Void
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.gearshape").font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("选择 marple 仓库目录").font(.title2.weight(.semibold))
            Text("需要包含 marple.config.json 和 rust/ 的目录。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("选择目录…") { pick() }.controlSize(.large).keyboardShortcut(.defaultAction)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try resolveVaultPaths(repoRoot: url.path)
            error = nil
            onPicked(url.path)
        } catch let e as VaultPathsError {
            switch e {
            case .missingConfig: error = "该目录缺少 marple.config.json,请选择 marple 仓库根目录。"
            case .badConfig(let m): error = "无法读取配置:\(m)"
            }
        } catch {
            self.error = "\(error)"
        }
    }
}
```

- [ ] **Step 2: Rewrite `MarpleApp.swift`**

```swift
import SwiftUI
import AppKit
import MarpleKit

final class AppState: ObservableObject {
    @Published var model: AppModel?
    @Published var booting = false
    @Published var bootError: String?
    private var sidecar: SidecarProcess?
    private var watcher: VaultWatcher?

    @MainActor
    func boot(paths: VaultPaths) async {
        guard model == nil, !booting else { return }
        booting = true; bootError = nil
        let sidecar = SidecarProcess(repoRoot: paths.repoRoot)
        self.sidecar = sidecar
        do {
            let base = try await sidecar.start()
            let client = HTTPVaultClient(baseURL: base)
            let m = AppModel(client: client, stateStore: UserDefaultsStateStore())
            await m.loadIndex()
            self.model = m
            self.booting = false
            let watcher = VaultWatcher(vaultDirectory: URL(fileURLWithPath: paths.vaultDir)) { [weak m] in
                await m?.reloadOpen()  // reloadOpen is @MainActor; await hops for us
            }
            watcher.start()
            self.watcher = watcher
        } catch {
            self.bootError = "\(error)"
            self.booting = false
        }
    }
}

@main
struct MarpleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    @AppStorage("marple.repoRoot") private var repoRoot = ""

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer so logs stream to the captured file
    }

    var body: some Scene {
        WindowGroup {
            content.frame(minWidth: 900, minHeight: 600)
        }
        .commands { TabCommands() }
    }

    @ViewBuilder private var content: some View {
        if let paths = resolvedPaths {
            if let model = state.model {
                RootView(model: model)
            } else if let err = state.bootError {
                ContentUnavailableView("启动失败", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else {
                ProgressView("启动 reader-api…")
                    .padding()
                    .task { await state.boot(paths: paths) }
            }
        } else {
            SetupView { picked in repoRoot = picked }
        }
    }

    private var resolvedPaths: VaultPaths? {
        guard !repoRoot.isEmpty else { return nil }
        return try? resolveVaultPaths(repoRoot: repoRoot)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running a SwiftUI app from `swift run` needs an explicit activation
        // policy + activate so the window comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
```

- [ ] **Step 3: Build**

Run: `cd apple && swift build`
Expected: builds clean.

- [ ] **Step 4: Seed the dev default so the picker doesn't gate daily use**

The app now starts at `SetupView` until a repo is chosen. For this dev machine, pre-seed the stored value once so the first launch boots straight through (the picker still appears on a clean machine / after a defaults reset):
```bash
defaults write Marple marple.repoRoot -string "/Users/ramudai/Documents/Learn/marple"
```
(Bundle id for a `swift run` executable defaults to the product name `Marple`; if the GUI still shows the picker, pick the repo folder once — it persists.)

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/Marple/SetupView.swift apple/Sources/Marple/MarpleApp.swift
git commit -m "feat(native): first-run vault picker, boot from resolved paths"
```

---

## Task 7: Full verification + handoff

- [ ] **Step 1: Full test suite**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: all suites pass (prior 120 + the new domain/workspace/persisted/vault tests).

- [ ] **Step 2: Clean build**

Run: `cd apple && swift build`
Expected: no errors, no new warnings beyond the carried NSTableView reentrant one.

- [ ] **Step 3: Write handoff** at `docs/superpowers/2026-05-23-marple-native-persistence-vault-picker-handoff.md` — what shipped, test counts, the GUI checklist below, and the deferred watcher-index-refresh note (rides the sidecar migration).

- [ ] **Step 4: Hand to user for GUI test.** Checklist:
  - Open a doc, switch panes, set a sort/filter, toggle list↔grid, open 2–3 tabs (pin one) → **quit and relaunch** → place is restored (tabs, active tab, open doc, pane, sort/filter, grid/list).
  - Delete the open doc externally, relaunch → that tab opens with no doc (no "load failed" wall).
  - Reset config (`defaults delete Marple marple.repoRoot`) → relaunch shows `SetupView`; pick the repo folder → boots; picking a non-repo folder shows the inline error.

---

## Self-Review

- **Spec coverage:** Persistence (tabs+pane+sort+filter+browseMode, restore, prune) → Tasks 1–4. Vault picker (resolve, setup UI, boot rewiring, no hardcoded paths) → Tasks 5–6. ✓
- **Placeholders:** none — all steps carry real code/commands. ✓
- **Type consistency:** `PersistedState`/`PersistedTab` fields match `persist()` (Task 4) and `makeWorkspace()` (Task 3); `resolveVaultPaths`→`VaultPaths(repoRoot,workspaceRoot,vaultDir)` consumed identically in `AppState.boot` (Task 6) and `SetupView` (Task 6). `Workspace(restoring:activeIndex:)` signature identical across Tasks 2/3. `BrowseMode(rawValue:)` ↔ `browseMode.rawValue` (Task 4). ✓
- **Coupling check:** no task references the sidecar internals, the HTTP index path, or search depth — the watcher-index-refresh is explicitly deferred. ✓
