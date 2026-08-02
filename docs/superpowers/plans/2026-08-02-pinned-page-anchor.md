# Pinned Page Anchor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every pinned page one durable anchor while preserving ordinary in-tab navigation, then make Command-W withdraw that navigation back to the anchor.

**Architecture:** `NavTab` owns one optional `pinnedLocation` beside its existing `NavHistory`; `location` remains the reader's live position and `identityLocation` resolves to the anchor only for stable pinned-page presentation and persistence. Pinning captures the current location, unpinning clears the anchor, and withdrawing replaces the active pinned tab's history with a fresh history rooted at the anchor. Existing `PersistedTab.location` stores the anchor for pinned tabs, so no persisted schema changes.

**Tech Stack:** Swift 6, SwiftUI/AppKit commands, Swift Observation, Swift Testing, SwiftPM.

## Global Constraints

- Work directly on `main`; do not create a branch or worktree.
- Keep one optional anchor state on `NavTab`; do not implement Peek, overlays, or a hover close button.
- Keep the sidebar context-menu **Close Page** action as the explicit pinned-page deletion path.
- Do not change the `PersistedTab` wire schema; a legacy pinned page adopts its currently persisted location as its anchor.
- Do not add fallback states, compatibility wrappers, or abstractions beyond the anchor operations used by this feature.
- Every production change follows a witnessed red-green TDD cycle.
- Preserve unrelated working-tree content and existing code style.

---

## File Map

- `apple/Sources/MarpleKit/Nav/Navigation.swift`: owns `NavTab` anchor state, pin/unpin invariants, withdrawal, and sidebar undo snapshots.
- `apple/Sources/Marple/App/AppModel.swift`: persists and presents pinned identity, and routes active-page close to withdrawal.
- `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`: resolves fixed-row title and icon from the anchor.
- `apple/Sources/Marple/Tabs/TabCommands.swift`: ensures Command-W reaches a pinned tab even when it is the only page.
- `apple/Tests/MarpleKitTests/NavigationTests.swift`: pure workspace anchor behavior.
- `apple/Tests/MarpleKitTests/NavigationContextTests.swift`: AppModel reader/list identity and Command-W behavior.
- `apple/Tests/MarpleKitTests/SidebarUndoTests.swift`: pin undo/redo preserves the anchor without rewinding later navigation.
- `apple/Tests/MarpleKitTests/AppModelLoadIndexTests.swift`: pinned persistence stores and restores the anchor.

---

### Task 1: Add the Anchor to the Navigation Model

**Files:**
- Modify: `apple/Sources/MarpleKit/Nav/Navigation.swift:63-91, 207-218, 319-345, 428-438, 517-520, 952-961`
- Test: `apple/Tests/MarpleKitTests/NavigationTests.swift:71-210`
- Test: `apple/Tests/MarpleKitTests/SidebarUndoTests.swift:32-46`

**Interfaces:**
- Produces: `NavTab.pinnedLocation: NavLocation?`
- Produces: `NavTab.identityLocation: NavLocation`
- Produces: `Workspace.withdrawActivePinnedNavigation() -> Bool`
- Updates: `Workspace.togglePin(_:)` captures or clears `pinnedLocation`.
- Updates: `WorkspaceSidebarState.TabValue` snapshots `pinnedLocation` for undo/redo.
- Updates: `Workspace.pruneOpenPaths(validPaths:)` applies the existing deleted-file rule to the anchor as well as the current location.

- [ ] **Step 1: Write failing pure-model tests**

Add these tests to `WorkspaceTests`:

```swift
@Test func pinnedTabKeepsItsAnchorWhileNavigationMoves() {
    var w = Workspace(initial: a)

    w.togglePin(w.activeID)
    w.navigateActive(to: b)
    w.navigateActive(to: c)

    #expect(w.activeTab.pinned)
    #expect(w.activeTab.pinnedLocation == a)
    #expect(w.activeTab.identityLocation == a)
    #expect(w.activeTab.location == c)
    #expect(w.activeTab.history.canGoBack)

    w.backActive()
    #expect(w.activeTab.location == b)
    #expect(w.activeTab.identityLocation == a)
    w.forwardActive()
    #expect(w.activeTab.location == c)
}

@Test func withdrawingPinnedNavigationReturnsToAnchorAndClearsExcursion() {
    var w = Workspace(initial: a)
    w.togglePin(w.activeID)
    w.navigateActive(to: b)
    w.navigateActive(to: c)

    #expect(w.withdrawActivePinnedNavigation())
    #expect(w.activeTab.location == a)
    #expect(w.activeTab.history.entries == [a])
    #expect(!w.activeTab.history.canGoBack)
    #expect(!w.withdrawActivePinnedNavigation())
}

@Test func unpinningKeepsCurrentNavigationAndClearsAnchor() {
    var w = Workspace(initial: a)
    w.togglePin(w.activeID)
    w.navigateActive(to: b)

    w.togglePin(w.activeID)

    #expect(!w.activeTab.pinned)
    #expect(w.activeTab.pinnedLocation == nil)
    #expect(w.activeTab.identityLocation == b)
    #expect(w.activeTab.location == b)
}

@Test func pruningADeletedPinnedPageAlsoPrunesItsAnchor() {
    let gone = NavLocation(pane: .type(.book), openPath: "gone.md")
    let keep = NavLocation(pane: .type(.chapter), openPath: "keep.md")
    var w = Workspace(initial: gone)
    w.togglePin(w.activeID)
    w.navigateActive(to: keep)

    w.pruneOpenPaths(validPaths: ["keep.md"])

    #expect(w.activeTab.location == keep)
    #expect(w.activeTab.pinnedLocation?.openPath == nil)
}
```

The production mutation each test catches is respectively: using `history.current` as fixed identity, failing to clear an excursion, and retaining anchor behavior after unpin.

- [ ] **Step 2: Run the pure-model tests and verify RED**

Run from `apple/`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter WorkspaceTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: compilation fails because `pinnedLocation`, `identityLocation`, and `withdrawActivePinnedNavigation()` do not exist. This is the required RED caused by the missing feature.

- [ ] **Step 3: Implement the minimal `NavTab` anchor**

Add one stored property, one computed identity, and an initializer default:

```swift
public struct NavTab: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var history: NavHistory
    public var pinned: Bool
    public var pinnedLocation: NavLocation?
    public var customTitle: String?
    public var cachedTitle: String?
    public var cachedType: EntryType?

    public init(id: UUID = UUID(), location: NavLocation, pinned: Bool = false,
                pinnedLocation: NavLocation? = nil,
                customTitle: String? = nil,
                cachedTitle: String? = nil,
                cachedType: EntryType? = nil) {
        self.id = id
        self.history = NavHistory(location)
        self.pinned = pinned
        self.pinnedLocation = pinned ? (pinnedLocation ?? location) : nil
        self.customTitle = customTitle
        self.cachedTitle = cachedTitle
        self.cachedType = cachedType
    }

    public var location: NavLocation { history.current }
    public var identityLocation: NavLocation { pinnedLocation ?? location }
}
```

Do not add anchor data to `NavHistory`; current reading history and fixed identity remain separate.

- [ ] **Step 4: Implement pin/unpin and withdrawal invariants**

Replace the boolean-only toggle and add the withdrawal operation:

```swift
public mutating func withdrawActivePinnedNavigation() -> Bool {
    guard tabs[activeIndex].pinned,
          let anchor = tabs[activeIndex].pinnedLocation,
          tabs[activeIndex].location != anchor else { return false }
    tabs[activeIndex].history = NavHistory(anchor)
    return true
}

public mutating func togglePin(_ id: NavTab.ID) {
    guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
    if tabs[i].pinned {
        tabs[i].pinned = false
        tabs[i].pinnedLocation = nil
    } else {
        tabs[i].pinned = true
        tabs[i].pinnedLocation = tabs[i].location
    }
    normalize()
}
```

Do not reset history when pinning or unpinning. Withdrawal is the only action that discards the excursion.

In `pruneOpenPaths`, apply the same current-location nulling rule to a missing
`pinnedLocation.openPath`:

```swift
if let anchor = tabs[i].pinnedLocation,
   let path = anchor.openPath, !validPaths.contains(path) {
    tabs[i].pinnedLocation = NavLocation(pane: anchor.pane, openPath: nil)
}
```

This is not a new recovery policy; it keeps the existing deleted-file behavior
consistent for the new stored location.

- [ ] **Step 5: Include the anchor in sidebar undo snapshots**

Extend `WorkspaceSidebarState.TabValue`, `sidebarState`, and `restoreSidebarState`:

```swift
public struct TabValue: Sendable, Equatable {
    public var pinned: Bool
    public var pinnedLocation: NavLocation?
    public var customTitle: String?
}
```

Snapshot with:

```swift
($0.id, .init(pinned: $0.pinned,
              pinnedLocation: $0.pinnedLocation,
              customTitle: $0.customTitle))
```

Restore with:

```swift
tabs[index].pinned = value.pinned
tabs[index].pinnedLocation = value.pinnedLocation
tabs[index].customTitle = value.customTitle
```

- [ ] **Step 6: Extend the pin undo test and verify GREEN**

In `pinUndoAndRedoRestoreThePinnedState`, capture the original location, navigate after pinning, then assert undo/redo changes only pinned identity:

```swift
let anchor = try #require(model.tabs.first { $0.id == ids[0] }?.location)
grouped(manager) { model.setPinned([ids[0]], to: true) }
await model.selectTab(ids[0])
await model.open("papers/later.md")

manager.undo()
let unpinned = try #require(model.tabs.first { $0.id == ids[0] })
#expect(!unpinned.pinned)
#expect(unpinned.pinnedLocation == nil)
#expect(unpinned.location.openPath == "papers/later.md")

manager.redo()
let repinned = try #require(model.tabs.first { $0.id == ids[0] })
#expect(repinned.pinned)
#expect(repinned.pinnedLocation == anchor)
#expect(repinned.location.openPath == "papers/later.md")
```

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter WorkspaceTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter SidebarUndoTests.pinUndoAndRedoRestoreThePinnedState \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: both commands pass; later navigation remains at `papers/later.md` through undo and redo.

- [ ] **Step 7: Commit the navigation model**

```bash
git add apple/Sources/MarpleKit/Nav/Navigation.swift \
  apple/Tests/MarpleKitTests/NavigationTests.swift \
  apple/Tests/MarpleKitTests/SidebarUndoTests.swift
git commit -m "feat: add pinned page anchors"
```

---

### Task 2: Use the Anchor as the Stable Pinned Identity

**Files:**
- Modify: `apple/Sources/Marple/App/AppModel.swift:330-345, 575-587, 1617-1628, 1917-2000`
- Modify: `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift:480-512`
- Test: `apple/Tests/MarpleKitTests/NavigationContextTests.swift`
- Test: `apple/Tests/MarpleKitTests/AppModelLoadIndexTests.swift`
- Test: `apple/Tests/MarpleKitTests/PersistedStateTests.swift:54-92`

**Interfaces:**
- Consumes: `NavTab.identityLocation`
- Consumes: `NavTab.pinnedLocation`
- Produces no new persistence type or field.
- Keeps: `AppModel.openPath` and reader loading use `NavTab.location`.

- [ ] **Step 1: Write failing stable-identity and persistence tests**

Add to `NavigationContextTests`:

```swift
@MainActor
@Test func pinnedTabNavigationKeepsItsAnchorInThePinnedListAndTitle() async throws {
    let book = entry("books/freedom.md", type: .book, year: "1999")
    let chapter = entry("books/freedom/ch04.md", type: .chapter, year: "1999")
    let model = AppModel(client: StubVaultClient(
        entries: [book, chapter],
        texts: [book.path: "# Freedom", chapter.path: "# Chapter 4"]))
    await model.loadIndex()
    await model.open(book.path)
    let id = try #require(model.activeTabID)
    model.togglePin(id)

    await model.open(chapter.path)

    let tab = try #require(model.tabs.first { $0.id == id })
    #expect(model.openPath == chapter.path)
    #expect(model.tabTitle(tab) == book.title)
    #expect(model.visibleEntries.map(\.path) == [book.path])
}
```

Add to `AppModelLoadIndexTests` using a fresh `UserDefaultsStateStore` suite:

```swift
@MainActor
@Test func pinnedTabPersistsItsAnchorInsteadOfCurrentExcursion() async throws {
    let book = Entry(
        path: "books/freedom.md", type: .book, title: "Development as Freedom",
        author: [], year: "1999", ratingScore: 0, themes: [], preview: "",
        hasPDF: false)
    let chapter = Entry(
        path: "books/freedom/ch04.md", type: .chapter, title: "Chapter 4",
        author: [], year: "1999", ratingScore: 0, themes: [], preview: "",
        hasPDF: false)
    let suite = "marple.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsStateStore(defaults: defaults)
    let model = AppModel(
        client: StubVaultClient(
            entries: [book, chapter],
            texts: [book.path: "# Freedom", chapter.path: "# Chapter 4"]),
        stateStore: store)
    await model.loadIndex()
    await model.open(book.path)
    let id = try #require(model.activeTabID)
    model.togglePin(id)

    await model.open(chapter.path)

    let state = try #require(store.load())
    let saved = try #require(state.spaces?.flatMap(\.tabs).first { $0.pinned })
    #expect(saved.location.openPath == book.path)
    let restored = try #require(state.makeWorkspace())
    #expect(restored.activeTab.location.openPath == book.path)
    #expect(restored.activeTab.pinnedLocation?.openPath == book.path)
}
```

Extend `WorkspaceRestoreTests.restoringBuildsTabsAndActive`:

```swift
#expect(ws.tabs[1].pinnedLocation?.openPath == "v/a.md")
#expect(ws.tabs[1].identityLocation.openPath == "v/a.md")
```

- [ ] **Step 2: Run the three focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter pinnedTabNavigationKeepsItsAnchor \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter pinnedTabPersistsItsAnchor \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: the presentation test reports the chapter title/path in pinned identity, and the persistence test saves the chapter rather than the book. The restore assertions may already pass after Task 1; they protect the no-schema migration boundary rather than serving as this task's RED.

- [ ] **Step 3: Persist the anchor through the existing wire field**

In `AppModel.persist`, resolve the stored location before cached metadata:

```swift
func persistedTab(_ tab: NavTab) -> PersistedTab {
    let location = tab.identityLocation
    let liveEntry = location.openPath.flatMap { liveByPath[$0] }
    let cachedTitle = liveEntry?.title ?? tab.cachedTitle
    let cachedType = liveEntry?.type ?? tab.cachedType
    return PersistedTab(location: location, pinned: tab.pinned,
                        customTitle: tab.customTitle,
                        cachedTitle: cachedTitle,
                        cachedType: cachedType)
}
```

Do not modify `PersistedTab`, its `CodingKeys`, or its decoder.

- [ ] **Step 4: Resolve stable pinned presentation from `identityLocation`**

Make these surgical substitutions:

```swift
// AppModel.visibleEntries pinned order
if let path = tab.identityLocation.openPath, order[path] == nil {
    order[path] = order.count
}

// AppModel.activateVisibleEntry pinned lookup
let id = tabs.first {
    $0.pinned && $0.identityLocation.openPath == path
}?.id

// AppModel.tabTitle / originalTabTitle / absolutePath
let loc = tab.identityLocation
```

In `SidebarTabOutlineView.Coordinator.tabNode`, resolve both entry and type from the identity:

```swift
let location = tab.identityLocation
let entry = location.openPath.flatMap { entryByPath[$0] }
let resolvedType = entry?.type ?? tab.cachedType
```

Then make its private `tabTitle` read `tab.identityLocation`. Do not change `AppModel.openPath`, document loading, back/forward, or `openTabPaths`; those continue to describe live navigation.

- [ ] **Step 5: Run focused presentation and persistence suites and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter NavigationContextTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter AppModelLoadIndexTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter WorkspaceRestoreTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: all three suites pass. The reader remains on chapter 4 while fixed identity and saved state remain on the book.

- [ ] **Step 6: Commit stable identity and persistence**

```bash
git add apple/Sources/Marple/App/AppModel.swift \
  apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift \
  apple/Tests/MarpleKitTests/NavigationContextTests.swift \
  apple/Tests/MarpleKitTests/AppModelLoadIndexTests.swift \
  apple/Tests/MarpleKitTests/PersistedStateTests.swift
git commit -m "fix: keep pinned page identity stable"
```

---

### Task 3: Make Command-W Withdraw Pinned Navigation

**Files:**
- Modify: `apple/Sources/Marple/App/AppModel.swift:1715-1727`
- Modify: `apple/Sources/Marple/Tabs/TabCommands.swift:20-33`
- Test: `apple/Tests/MarpleKitTests/NavigationContextTests.swift`

**Interfaces:**
- Consumes: `Workspace.withdrawActivePinnedNavigation() -> Bool`
- Updates: `AppModel.closeActiveTab()` withdraws a pinned excursion or closes an unpinned page.
- Keeps: `AppModel.closeTab(_:)` directly closes pinned pages for the sidebar context menu.

- [ ] **Step 1: Write failing AppModel withdrawal tests**

Add to `NavigationContextTests`:

```swift
@MainActor
@Test func closeActiveTabWithdrawsPinnedExcursionWithoutClosingPage() async throws {
    let book = entry("books/freedom.md", type: .book, year: "1999")
    let chapter = entry("books/freedom/ch04.md", type: .chapter, year: "1999")
    let model = AppModel(client: StubVaultClient(
        entries: [book, chapter],
        texts: [book.path: "# Freedom", chapter.path: "# Chapter 4"]))
    await model.loadIndex()
    await model.open(book.path)
    let id = try #require(model.activeTabID)
    model.togglePin(id)
    await model.open(chapter.path)

    await model.closeActiveTab()

    #expect(model.tabs.map(\.id) == [id])
    #expect(model.tabs.first?.pinned == true)
    #expect(model.openPath == book.path)
    #expect(model.tabs.first?.history.entries.map(\.openPath) == [book.path])

    let history = try #require(model.tabs.first?.history)
    await model.closeActiveTab()
    #expect(model.tabs.first?.history == history)
}
```

This test catches the current pinned no-op branch and prevents a future implementation from deleting the pinned page.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter closeActiveTabWithdrawsPinnedExcursion \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: FAIL because `openPath` remains chapter 4 after `closeActiveTab()`.

- [ ] **Step 3: Route pinned close through withdrawal**

Replace `closeActiveTab()` with the minimal branch:

```swift
func closeActiveTab() async {
    guard !isBrowsing, var workspace else { return }
    if workspace.activeTab.pinned {
        guard workspace.withdrawActivePinnedNavigation() else { return }
        self.workspace = workspace
        await syncToActiveLocation(from: true)
        return
    }
    guard let id = activeTabID else { return }
    await closeTab(id)
}
```

Do not route sidebar `closeTab(_:)` through this method; right-click close must still remove pinned pages.

- [ ] **Step 4: Ensure Command-W reaches a lone pinned page**

Change only the existing command guard in `TabCommands`:

```swift
if let m = ActiveModel.current, m.isPinnedListContext || m.tabs.count > 1 {
    Task { await m.closeActiveTab() }
} else {
    NSApp.keyWindow?.performClose(nil)
}
```

This preserves the current one-temporary-page window-close behavior while making Command-W a pinned-anchor command even when only one pinned page exists.

- [ ] **Step 5: Verify withdrawal and direct pinned close**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter NavigationContextTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter SidebarUndoTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: both suites pass. Existing `undoCloseRestoresPlacementHistoryContextAndActiveTab` continues proving that the direct close path carries the whole tab; the new test proves Command-W never deletes the pin.

- [ ] **Step 6: Commit Command-W withdrawal**

```bash
git add apple/Sources/Marple/App/AppModel.swift \
  apple/Sources/Marple/Tabs/TabCommands.swift \
  apple/Tests/MarpleKitTests/NavigationContextTests.swift
git commit -m "feat: withdraw pinned navigation with command w"
```

---

### Task 4: Review, Full Verification, and Signed Test Install

**Files:**
- Review only: all files changed by Tasks 1-3
- No production edits unless a reviewer identifies a verified Critical or Important defect.

**Interfaces:**
- Consumes the completed feature.
- Produces a Developer ID-signed `/Applications/Marple.app` for user testing.

- [ ] **Step 1: Run diff hygiene checks**

Run separately from the repository root:

```bash
git diff --check
git status --short --branch
```

Expected: no whitespace errors and only intentional changes, or a clean tree after the task commits.

- [ ] **Step 2: Request two independent reviews**

Send the complete diff and design to the existing architecture and interaction reviewers. Ask each to report only:

- Critical: data loss, corrupted persisted state, pinned page deletion, broken close path;
- Important: anchor/current identity mismatch, undo history rewind, lone-tab Command-W regression;
- Minor: optional simplifications that do not justify extra state.

Apply Critical or Important findings only after reproducing them. Do not add defensive branches for speculative Minor findings.

- [ ] **Step 3: Run the full Swift test suite**

Run from `apple/`, redirecting output so the test helper does not receive SIGPIPE from output truncation:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks \
  > /private/tmp/marple-full-test.log 2>&1
```

Expected: exit 0 and the final log line reports all tests and suites passed.

- [ ] **Step 4: Build and verify a signed release bundle**

Use the existing ignored `apple/Makefile.local` identity and the `macos-signing` skill. From `apple/`, build into a validated fresh temporary directory with explicit release, signing, marketing version, and commit-count build number:

```bash
MARPLE_BUILD_ROOT="$(mktemp -d /private/tmp/marple-signed-build.XXXXXX)"
case "$MARPLE_BUILD_ROOT" in
  /private/tmp/marple-signed-build.*) ;;
  *) exit 1 ;;
esac
MARPLE_BUILD_NUMBER="$(git rev-list --count HEAD)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
CONFIG=release SIGN=1 VERSION=0.2.10 BUILD="$MARPLE_BUILD_NUMBER" \
APP_DIR="$MARPLE_BUILD_ROOT/Marple.app" \
CODESIGN_IDENTITY="Developer ID Application: Ningxiang Sun (2E5N3Q45BG)" \
./build-app.sh
codesign --verify --deep --strict --verbose=2 "$MARPLE_BUILD_ROOT/Marple.app"
codesign -dv --verbose=4 "$MARPLE_BUILD_ROOT/Marple.app"
plutil -extract CFBundleVersion raw -o - "$MARPLE_BUILD_ROOT/Marple.app/Contents/Info.plist"
```

Expected: valid on disk, satisfies its Designated Requirement, authority `Developer ID Application: Ningxiang Sun (2E5N3Q45BG)`, and the expected build number.

- [ ] **Step 5: Back up state, replace the app, and launch one instance**

Before replacement, quit the single `/Applications/Marple.app` process normally and create a validated rollback directory:

```bash
MARPLE_ROLLBACK_ROOT="$(mktemp -d /private/tmp/marple-install-rollback.XXXXXX)"
case "$MARPLE_ROLLBACK_ROOT" in
  /private/tmp/marple-install-rollback.*) ;;
  *) exit 1 ;;
esac
```

Store these three recoverable copies beneath `$MARPLE_ROLLBACK_ROOT`:

- the existing `/Applications/Marple.app`;
- `/Users/ramudai/Library/Preferences/com.marple.app.plist`;
- `defaults export com.marple.app` output.

Read `CFBundleVersion` from the new bundle into `MARPLE_BUILD_NUMBER`, stage it at `/Applications/Marple-$MARPLE_BUILD_NUMBER.staging.app`, verify it again, move the old installation into `$MARPLE_ROLLBACK_ROOT`, and promote the staged bundle. Launch with:

```bash
open /Applications/Marple.app
```

Never use `open -n`. Confirm exactly one process whose executable path is `/Applications/Marple.app/Contents/MacOS/Marple`.

- [ ] **Step 6: Hand off the exact manual check**

Ask the user to pin `Development as Freedom`, navigate to chapter 4, confirm the fixed row still reads `Development as Freedom`, then press Command-W and confirm the reader returns to the book. Also confirm right-click **Close Page** still removes the pin when explicitly chosen.
