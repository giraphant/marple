# Sidebar Hotfix and Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair fixed/temporary page interactions, restore each temporary page's semantic list context, and make the agreed sidebar structure edits participate in native macOS undo and redo.

**Architecture:** `NavLocation` owns one optional `ListContext`; `AppModel` captures it only for temporary pages and applies it before list selection synchronises. Sidebar edits register narrow inverse values with the window's `UndoManager`: ordinary page-tree edits restore topology/pin/title fields, closing uses a dedicated removed-tab record, and type/saved-view edits restore their old collections. The implementation uses existing `Workspace` mutations and native event grouping; it does not add a custom transaction stack, nesting counter, or general state-merging framework.

**Tech Stack:** Swift 6, Swift Testing, Observation, AppKit `NSOutlineView`, Foundation `UndoManager`, Swift Package Manager, existing MarpleKit navigation and persistence models.

## Global Constraints

- Work directly on `main`; do not create a branch or worktree.
- Keep changes surgical and dependency-free; do not refactor adjacent navigation, persistence, or sidebar rendering code.
- Use the established container-capability pattern checked in `/tmp/marple-reference-repos/NetNewsWire`: an outline container remains expandable when empty.
- One user gesture must produce one undo step. Rely on the window `UndoManager`'s native event grouping; do not add a custom transaction-depth mechanism.
- Undo only pin/unpin, page/group move/reorder/group/rename, page close variants, object-type order/visibility, and saved-view order/rename/delete.
- Do not register selection, open/navigation/history traversal, scroll, expand/collapse, Space management/deletion, or vault file operations with this undo manager.
- Undoing a non-close sidebar edit must preserve later navigation histories. Undoing close must restore removed tabs' captured histories while preserving current histories of tabs that survived the close.
- A named saved view's current shared filter/sort definition is authoritative when its temporary page is restored.
- Do not expose private AppKit hierarchy or drag hit-testing solely for tests; verify those paths with the final manual smoke test.
- Commit after each independently passing task. Do not push, merge, publish, or create a release.

---

## File Map

- Modify `apple/Sources/MarpleKit/Nav/Navigation.swift`: add `ListContext`, update `NavLocation`, add active-location replacement, and define the narrow workspace undo records/restoration methods.
- Modify `apple/Sources/Marple/App/AppModel.swift`: capture/apply temporary list context and register all in-scope model intents with `UndoManager`.
- Modify `apple/Sources/Marple/App/MarpleWindowController.swift`: own and vend the session-scoped window undo manager.
- Modify `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`: keep the empty fixed section drop-capable, expose grouping for temporary pages, and remove the redundant pin glyph.
- Modify `apple/Sources/Marple/Resources/Localizable.xcstrings`: add the small set of undo action names that do not already exist.
- Modify `apple/Tests/MarpleKitTests/PersistedStateTests.swift`: cover `ListContext` persistence and legacy decoding.
- Modify `apple/Tests/MarpleKitTests/NavigationContextTests.swift`: replace the obsolete shared-context expectation with complete temporary-context restoration and saved-view authority tests.
- Create `apple/Tests/MarpleKitTests/SidebarUndoTests.swift`: cover high-level grouping, ordinary structure undo/redo, close restoration, and type/saved-view undo.

### Task 1: Persist a Cohesive Temporary-Page List Context

**Files:**
- Modify: `apple/Sources/MarpleKit/Nav/Navigation.swift:1-37`
- Modify: `apple/Tests/MarpleKitTests/PersistedStateTests.swift:1-34`

**Interfaces:**
- Produces: `public struct ListContext: Hashable, Sendable, Codable`
- Produces: `NavLocation.init(pane:openPath:listContext:)`
- Produces: `public mutating func Workspace.replaceActiveLocation(with:)`
- Compatibility: decoding an older `NavLocation` without `listContext` yields `nil`.

- [ ] **Step 1: Add failing persistence and legacy-decode tests**

Replace `navLocationRoundTrips` and add a file-private legacy encoder:

```swift
    @Test func navLocationRoundTripsWithListContext() throws {
        let context = ListContext(
            searchText: "agency",
            filters: [FilterClause(id: "year", field: .year, op: .gte, value: "2020")],
            filterMatch: .any,
            sorts: [SortClause(field: .title, dir: .asc)])
        let loc = NavLocation(pane: .theme("X"), openPath: "vault/a.md",
                              listContext: context)
        let data = try JSONEncoder().encode(loc)
        #expect(try JSONDecoder().decode(NavLocation.self, from: data) == loc)
    }

    @Test func legacyNavLocationDecodesWithoutListContext() throws {
        let data = try JSONEncoder().encode(
            LegacyNavLocation(pane: .type(.paper), openPath: "vault/a.md"))
        let decoded = try JSONDecoder().decode(NavLocation.self, from: data)
        #expect(decoded.pane == .type(.paper))
        #expect(decoded.openPath == "vault/a.md")
        #expect(decoded.listContext == nil)
    }
```

Add at file scope:

```swift
private struct LegacyNavLocation: Encodable {
    let pane: Pane
    let openPath: String?
}
```

- [ ] **Step 2: Run the focused tests and confirm the new API is missing**

Run:

```bash
cd apple
swift test --filter DomainCodableTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: compilation fails because `ListContext` and `NavLocation.listContext` do not exist.

- [ ] **Step 3: Add the minimal navigation-domain implementation**

Insert before `NavLocation` and extend its initializer:

```swift
public struct ListContext: Hashable, Sendable, Codable {
    public var searchText: String
    public var filters: [FilterClause]
    public var filterMatch: FilterMatch
    public var sorts: [SortClause]

    public init(searchText: String, filters: [FilterClause],
                filterMatch: FilterMatch, sorts: [SortClause]) {
        self.searchText = searchText
        self.filters = filters
        self.filterMatch = filterMatch
        self.sorts = sorts
    }
}

public struct NavLocation: Hashable, Sendable, Codable {
    public var pane: Pane
    public var openPath: String?
    public var listContext: ListContext?

    public init(pane: Pane, openPath: String? = nil, listContext: ListContext? = nil) {
        self.pane = pane
        self.openPath = openPath
        self.listContext = listContext
    }
}
```

Next to the other active-history methods, add:

```swift
    public mutating func replaceActiveLocation(with location: NavLocation) {
        tabs[activeIndex].history.replaceCurrent(with: location)
    }
```

Use synthesized `Codable`; an optional synthesized property already uses `decodeIfPresent`, so no custom decoder is needed.

- [ ] **Step 4: Run the focused persistence tests**

Run:

```bash
cd apple
swift test --filter DomainCodableTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: all `DomainCodableTests` pass, including the legacy blob with `listContext == nil`.

- [ ] **Step 5: Commit the domain change**

```bash
git add apple/Sources/MarpleKit/Nav/Navigation.swift apple/Tests/MarpleKitTests/PersistedStateTests.swift
git commit -m "feat: persist temporary page list context"
```

### Task 2: Restore the Complete Temporary-Page List Scene

**Files:**
- Modify: `apple/Tests/MarpleKitTests/NavigationContextTests.swift:1-125`
- Modify: `apple/Sources/Marple/App/AppModel.swift:224-275, 960-1070, 1120-1225, 1340-1505`

**Interfaces:**
- Consumes: `ListContext` and `Workspace.replaceActiveLocation(with:)` from Task 1.
- Produces: `private var currentBrowseListContext: ListContext`.
- Produces: `private func updateActiveTemporaryListContext()`.
- Produces: `private func applyActiveListContext(from:)` used synchronously by tab selection, history navigation, and active pin changes.

- [ ] **Step 1: Replace the obsolete shared-context test with a restoration test**

Replace `temporaryTabsShareTheCurrentBrowseContext` with:

```swift
    @MainActor
    @Test func temporaryTabRestoresCompleteListContext() async throws {
        let author = entry("authors/clare.md", type: .author, year: "2024")
        let book = entry("books/habit.md", type: .book, year: "2018")
        let authorFilter = FilterClause(
            id: "recent", field: .year, op: .gte, value: "2020")
        let authorSort = [SortClause(field: .title, dir: .desc)]
        let client = StubVaultClient(
            entries: [author, book],
            texts: [author.path: "# Clare", book.path: "# Habit"],
            hits: [SearchHit(entry: author, score: 1, snippet: nil, source: "test")])
        let model = AppModel(client: client)
        await model.loadIndex()

        model.select(pane: .type(.author))
        await model.open(author.path)
        let authorTab = try #require(model.activeTabID)
        model.setFilters([authorFilter], match: .any)
        model.setSort(authorSort)
        model.setSearchText("clare")
        await waitForEntries([author.path], in: model)

        model.select(pane: .type(.book))
        model.setFilters([], match: .all)
        model.setSort([SortClause(field: .year, dir: .asc)])
        model.setSearchText("")
        await model.open(book.path)
        await model.selectTab(authorTab)

        #expect(model.pane == .type(.author))
        #expect(model.searchText == "clare")
        #expect(model.activeFilterClauses == [authorFilter])
        #expect(model.activeFilterMatch == .any)
        #expect(model.activeSortClauses == authorSort)
        #expect(model.openPath == author.path)
        #expect(model.visibleEntries.map(\.path) == [author.path])
    }
```

Change the local entry helper so the test can use a meaningful ready filter:

```swift
    private func entry(_ path: String, type: EntryType,
                       year: String? = nil, hasPDF: Bool = false) -> Entry {
        Entry(path: path, type: type, title: path, author: [], year: year,
              ratingScore: 0, themes: [], preview: "", hasPDF: hasPDF)
    }
```

- [ ] **Step 2: Add a failing saved-view authority test**

Add to `NavigationContextTests`:

```swift
    @MainActor
    @Test func savedViewTabUsesTheLatestSharedDefinition() async throws {
        let oldPaper = entry("papers/old.md", type: .paper, year: "1999")
        let newPaper = entry("papers/new.md", type: .paper, year: "2025")
        let model = AppModel(client: StubVaultClient(
            entries: [oldPaper, newPaper],
            texts: [oldPaper.path: "# Old", newPaper.path: "# New"]))
        await model.loadIndex()

        model.select(pane: .type(.paper))
        model.setFilters([FilterClause(id: "old", field: .year, op: .lte, value: "2000")])
        let viewID = model.createSavedView(named: "论文视图").id
        await model.open(oldPaper.path)
        let viewTab = try #require(model.activeTabID)

        model.select(pane: .savedView(viewID))
        let latest = FilterClause(id: "new", field: .year, op: .gte, value: "2020")
        let latestSort = [SortClause(field: .year, dir: .desc)]
        model.setFilters([latest], match: .all)
        model.setSort(latestSort)
        await model.selectTab(viewTab)
        await waitForEntries([newPaper.path], in: model)

        #expect(model.pane == .savedView(viewID))
        #expect(model.activeFilterClauses == [latest])
        #expect(model.activeSortClauses == latestSort)
        #expect(model.visibleEntries.map(\.path) == [newPaper.path])
    }
```

- [ ] **Step 3: Run the focused tests and verify the old behavior fails**

Run:

```bash
cd apple
swift test --filter NavigationContextTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: `temporaryTabRestoresCompleteListContext` fails because selecting the author tab leaves the book pane/global controls active. The saved-view test must remain red until the location's pane is reapplied.

- [ ] **Step 4: Add context capture and active-location updates in `AppModel`**

Add beside the browse/search state helpers:

```swift
    private var currentBrowseListContext: ListContext {
        ListContext(searchText: searchText,
                    filters: activeFilterClauses,
                    filterMatch: activeFilterMatch,
                    sorts: activeSortClauses)
    }

    private func updateActiveTemporaryListContext() {
        guard !isBrowsing, let active = workspace?.activeTab, !active.pinned else { return }
        var location = active.location
        location.pane = browsePane
        location.listContext = currentBrowseListContext
        mutateWorkspace { $0.replaceActiveLocation(with: location) }
    }
```

Call `updateActiveTemporaryListContext()` after each effective `setSearchText`, `setFilters`, and `setSort` mutation, after their stored properties have been updated. Keep each method's existing no-op guard and recompute/search behavior.

- [ ] **Step 5: Apply temporary context synchronously before list/document sync**

Add:

```swift
    private func applyActiveListContext(from previousPinnedContext: Bool? = nil) {
        guard !isBrowsing, let active = workspace?.activeTab else { return }
        if active.pinned {
            if previousPinnedContext != true || searchText != pinnedSearchText {
                resetSearch(to: pinnedSearchText)
            }
            return
        }

        let location = active.location
        browsePane = location.pane
        if let context = location.listContext {
            if case .savedView = location.pane {
                // The named view's current shared definition remains authoritative.
            } else {
                filterClauses = context.filters
                filterMatch = context.filterMatch
                sortClauses = context.sorts
            }
            browseSearchText = context.searchText
            resetSearch(to: context.searchText)
        } else if previousPinnedContext == true {
            resetSearch(to: browseSearchText)
        } else {
            recomputeVisible()
        }
    }
```

Make `syncToActiveLocation(from:)` begin with `applyActiveListContext(from:)` and remove its old two-search-context conditional. Keep reader-highlight clearing and conditional document loading unchanged.

After `setPinned` mutates an active tab, call `applyActiveListContext(from: previousPinnedContext)` synchronously instead of directly choosing `pinnedSearchText`/`browseSearchText`. This preserves the existing immediate expectations after pin/unpin.

- [ ] **Step 6: Capture the correct source context without leaking the pinned-list search**

Replace `sourceLocation(for:)` with:

```swift
    private func sourceLocation(for path: String) -> NavLocation {
        if isPinnedListContext, let location = workspace?.activeTab.location {
            return NavLocation(pane: location.pane, openPath: path,
                               listContext: location.listContext)
        }
        return NavLocation(pane: browsePane, openPath: path,
                           listContext: currentBrowseListContext)
    }
```

Leave `select(pane:)` as a browsing action: it must not overwrite the inactive document tab's context.

- [ ] **Step 7: Run the context tests and persistence tests**

Run:

```bash
cd apple
swift test --filter NavigationContextTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --filter DomainCodableTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: both suites pass. In particular, pinned tabs still share `pinnedSearchText`, unpin restores the saved temporary context, and named views use their latest definitions.

- [ ] **Step 8: Commit complete list restoration**

```bash
git add apple/Sources/Marple/App/AppModel.swift apple/Tests/MarpleKitTests/NavigationContextTests.swift
git commit -m "fix: restore temporary page list context"
```

### Task 3: Repair Empty Fixed Drops, Group Temporary Pages, and Remove Pin Glyphs

**Files:**
- Create: `apple/Tests/MarpleKitTests/SidebarUndoTests.swift`
- Modify: `apple/Sources/Marple/App/AppModel.swift:1440-1455`
- Modify: `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift:665-669, 834-865, 1830-1960`

**Interfaces:**
- Produces: `AppModel.groupTabs(_:)` as the single high-level group intent that pins valid selected tabs before calling `Workspace.groupTabs`.
- Keeps: `SidebarOutlineNode.pinned` as behavioral state; removes only `SidebarOutlineCellView.pinImageView` presentation.

- [ ] **Step 1: Add a failing model test for grouping temporary pages**

Create `SidebarUndoTests.swift` with:

```swift
import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct SidebarUndoTests {
    @MainActor
    @Test func groupingTemporaryPagesPinsThemInVisualOrder() async throws {
        let first = sidebarEntry("papers/first.md")
        let second = sidebarEntry("papers/second.md")
        let third = sidebarEntry("papers/third.md")
        let model = AppModel(client: StubVaultClient(
            entries: [first, second, third],
            texts: [first.path: "# First", second.path: "# Second", third.path: "# Third"]))
        await model.loadIndex()
        await model.open(first.path)
        let firstID = try #require(model.activeTabID)
        await model.openInNewTab(second.path)
        let secondID = try #require(model.activeTabID)
        await model.openInNewTab(third.path)

        model.groupTabs([secondID, firstID])

        let group = try #require(model.tabGroups.first)
        #expect(model.tabs(in: group.id).map(\.id) == [firstID, secondID])
        #expect(model.tabs(in: group.id).allSatisfy(\.pinned))
        #expect(model.pinnedTabRootNodes == [.group(group)])
        #expect(model.temporaryTabs.map(\.location.openPath) == [third.path])
    }
}

private func sidebarEntry(_ path: String) -> Entry {
    Entry(path: path, type: .paper, title: path, author: [], year: nil,
          ratingScore: 0, themes: [], preview: "", hasPDF: false)
}
```

- [ ] **Step 2: Run the new test and confirm temporary grouping is ineffective**

Run:

```bash
cd apple
swift test --filter SidebarUndoTests.groupingTemporaryPagesPinsThemInVisualOrder -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: the group is absent after `flattenTemporaryTabs()` because the selected pages remain temporary.

- [ ] **Step 3: Make grouping one minimal high-level model intent**

Replace the one-line `AppModel.groupTabs` with:

```swift
    func groupTabs(_ ids: [NavTab.ID]) {
        let valid = tabs.filter { ids.contains($0.id) }.map(\.id)
        guard Set(valid).count >= 2 else { return }
        mutateWorkspace { workspace in
            for id in valid where workspace.tabs.first(where: { $0.id == id })?.pinned == false {
                workspace.togglePin(id)
            }
            workspace.groupTabs(valid)
        }
    }
```

Do not call `setPinned` from this method; the combined mutation must remain one model intent and later one undo registration.

- [ ] **Step 4: Apply the three surgical AppKit changes**

In `isItemExpandable`, replace the child-count-only result with:

```swift
            return node.isPinnedSection || !node.children.isEmpty
```

In `batchMenuItems`, remove `allPinnedTabs` and gate the group item with `if allTabs`. Keep pure-tab ID extraction and the existing localized menu title.

Remove these `SidebarOutlineCellView` pieces and nothing else:

```swift
private let pinImageView = NSImageView()
pinImageView.isHidden = !node.pinned
pinImageView.menu = nil
```

Also remove its image setup, `stack.addArrangedSubview(pinImageView)`, and its two width/height constraints. Keep `node.pinned` because drop validation, menu actions, and list-section behavior still use it.

- [ ] **Step 5: Run the model test and compile the AppKit target**

Run:

```bash
cd apple
swift test --filter SidebarUndoTests.groupingTemporaryPagesPinsThemInVisualOrder -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift build -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: the model test passes and `Marple` compiles without references to `pinImageView`.

- [ ] **Step 6: Commit the fixed/temporary interaction hotfix**

```bash
git add apple/Sources/Marple/App/AppModel.swift apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift apple/Tests/MarpleKitTests/SidebarUndoTests.swift
git commit -m "fix: repair fixed page sidebar interactions"
```

### Task 4: Add Narrow Undo for Ordinary Page-Tree Edits

**Files:**
- Modify: `apple/Sources/MarpleKit/Nav/Navigation.swift:177-230, 340-780`
- Modify: `apple/Sources/Marple/App/AppModel.swift:1-25, 190-235, 820-880, 1440-1585`
- Modify: `apple/Sources/Marple/App/MarpleWindowController.swift:1-125`
- Modify: `apple/Sources/Marple/Resources/Localizable.xcstrings`
- Modify: `apple/Tests/MarpleKitTests/SidebarUndoTests.swift`

**Interfaces:**
- Produces: `public struct WorkspaceSidebarState: Sendable, Equatable` containing root topology plus per-tab pin/title values, but no navigation history.
- Produces: `Workspace.sidebarState` and `Workspace.restoreSidebarState(_:)`.
- Produces: `@ObservationIgnored weak var AppModel.undoManager: UndoManager?`.
- Produces: `private func mutateSidebarWorkspace(actionName:_:)` and inverse-registration helpers.
- Produces: `MarpleWindowController.windowWillReturnUndoManager(_:)`.

- [ ] **Step 1: Add failing ordinary undo/redo tests**

Append to `SidebarUndoTests`:

```swift
    @MainActor
    @Test func groupingIsOneUndoStepAndRedoReappliesIt() async throws {
        let (model, ids) = try await modelWithThreeTabs()
        let manager = attachUndoManager(to: model)

        grouped(manager) { model.groupTabs([ids[1], ids[0]]) }
        #expect(model.tabGroups.count == 1)
        #expect(model.tabs.filter(\.pinned).map(\.id) == [ids[0], ids[1]])

        manager.undo()
        #expect(model.tabGroups.isEmpty)
        #expect(model.tabs.allSatisfy { !$0.pinned })
        #expect(!manager.canUndo)
        #expect(manager.canRedo)

        manager.redo()
        #expect(model.tabGroups.count == 1)
        #expect(model.tabs.filter(\.pinned).map(\.id) == [ids[0], ids[1]])
    }

    @MainActor
    @Test func moveAndRenameRoundTripWithoutRewindingHistory() async throws {
        let (model, ids) = try await modelWithThreeTabs()
        model.togglePin(ids[0])
        model.togglePin(ids[1])
        model.groupTabs([ids[0], ids[1]])
        let groupID = try #require(model.tabGroups.first?.id)
        let originalName = try #require(model.tabGroups.first?.name)
        let manager = attachUndoManager(to: model)

        grouped(manager) {
            model.moveTab(ids[1], toGroup: groupID, at: 0)
            model.renameTab(ids[1], to: "Second renamed")
            model.renameTabGroup(groupID, to: "Research")
        }
        await model.selectTab(ids[2])
        await model.open("papers/later.md")
        let survivingHistory = try #require(model.tabs.first { $0.id == ids[2] }?.history)

        manager.undo()
        #expect(model.tabGroup(containing: ids[1])?.id == groupID)
        #expect(model.tabs(in: groupID).map(\.id) == [ids[0], ids[1]])
        #expect(model.tabs.first { $0.id == ids[1] }?.customTitle == nil)
        #expect(model.tabGroups.first { $0.id == groupID }?.name == originalName)
        #expect(model.tabs.first { $0.id == ids[2] }?.history == survivingHistory)

        manager.redo()
        #expect(model.tabs(in: groupID).map(\.id) == [ids[1], ids[0]])
        #expect(model.tabs.first { $0.id == ids[1] }?.customTitle == "Second renamed")
        #expect(model.tabGroups.first { $0.id == groupID }?.name == "Research")
        #expect(model.tabs.first { $0.id == ids[2] }?.history == survivingHistory)
    }

    @MainActor
    @Test func expandCollapseDoesNotRegisterUndoOrGetRewound() async throws {
        let (model, ids) = try await modelWithThreeTabs()
        model.setPinned([ids[0], ids[1]], to: true)
        model.groupTabs([ids[0], ids[1]])
        let groupID = try #require(model.tabGroups.first?.id)
        let manager = attachUndoManager(to: model)

        model.toggleTabGroup(groupID)
        #expect(!manager.canUndo)
        grouped(manager) { model.renameTabGroup(groupID, to: "Renamed") }
        model.toggleTabGroup(groupID)
        manager.undo()

        #expect(model.tabGroups.first { $0.id == groupID }?.name != "Renamed")
        #expect(model.tabGroups.first { $0.id == groupID }?.isCollapsed == false)
    }

    @MainActor
    @Test func crossSpaceMoveUndoRestoresBothOwners() async throws {
        let (model, ids) = try await modelWithThreeTabs()
        let sourceSpaceID = try #require(model.activeSpaceID)
        model.addSpace()
        let destinationSpaceID = try #require(model.activeSpaceID)
        await model.open("papers/later.md")
        let destinationTabID = try #require(model.activeTabID)
        let manager = attachUndoManager(to: model)

        grouped(manager) {
            model.moveItems([.tab(ids[0])], from: sourceSpaceID, toRootAt: 0)
        }
        #expect(model.spaces.first { $0.id == destinationSpaceID }?
            .workspace?.tabs.map(\.id) == [ids[0], destinationTabID])

        manager.undo()
        #expect(model.spaces.first { $0.id == sourceSpaceID }?
            .workspace?.tabs.map(\.id) == ids)
        #expect(model.spaces.first { $0.id == destinationSpaceID }?
            .workspace?.tabs.map(\.id) == [destinationTabID])
    }
```

Add these helpers at file scope; include `papers/later.md` in the stub entries/texts returned by `modelWithThreeTabs`:

```swift
@MainActor
private func attachUndoManager(to model: AppModel) -> UndoManager {
    let manager = UndoManager()
    model.undoManager = manager
    return manager
}

private func grouped(_ manager: UndoManager, _ action: () -> Void) {
    manager.beginUndoGrouping()
    action()
    manager.endUndoGrouping()
}

@MainActor
private func grouped(_ manager: UndoManager, _ action: () async -> Void) async {
    manager.beginUndoGrouping()
    await action()
    manager.endUndoGrouping()
}

@MainActor
private func modelWithThreeTabs() async throws -> (AppModel, [NavTab.ID]) {
    let paths = ["papers/first.md", "papers/second.md", "papers/third.md", "papers/later.md"]
    let entries = paths.map(sidebarEntry)
    let model = AppModel(client: StubVaultClient(
        entries: entries,
        texts: Dictionary(uniqueKeysWithValues: paths.map { ($0, "# \($0)") })))
    await model.loadIndex()
    var ids: [NavTab.ID] = []
    await model.open(paths[0]); ids.append(try #require(model.activeTabID))
    await model.openInNewTab(paths[1]); ids.append(try #require(model.activeTabID))
    await model.openInNewTab(paths[2]); ids.append(try #require(model.activeTabID))
    return (model, ids)
}
```

- [ ] **Step 2: Run the ordinary undo tests and confirm `undoManager` is missing**

Run:

```bash
cd apple
swift test --filter SidebarUndoTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: compilation fails because `AppModel.undoManager` and undo registrations do not exist.

- [ ] **Step 3: Define the narrow workspace sidebar state**

Add in `Navigation.swift` before `Workspace`:

```swift
public struct WorkspaceSidebarState: Sendable, Equatable {
    public struct TabValue: Sendable, Equatable {
        public var pinned: Bool
        public var customTitle: String?
    }

    fileprivate var root: [TabNode]
    fileprivate var values: [NavTab.ID: TabValue]
}
```

Add to `Workspace`:

```swift
    public var sidebarState: WorkspaceSidebarState {
        WorkspaceSidebarState(
            root: root,
            values: Dictionary(uniqueKeysWithValues: tabs.map {
                ($0.id, .init(pinned: $0.pinned, customTitle: $0.customTitle))
            }))
    }

    public mutating func restoreSidebarState(_ state: WorkspaceSidebarState) {
        let collapsed = Dictionary(uniqueKeysWithValues: tabGroups.map { ($0.id, $0.isCollapsed) })
        func preservingCollapse(_ nodes: [TabNode]) -> [TabNode] {
            nodes.map { node in
                guard case .group(var group) = node else { return node }
                group.isCollapsed = collapsed[group.id] ?? group.isCollapsed
                group.children = preservingCollapse(group.children)
                return .group(group)
            }
        }

        root = preservingCollapse(state.root)
        for index in tabs.indices {
            guard let value = state.values[tabs[index].id] else { continue }
            tabs[index].pinned = value.pinned
            tabs[index].customTitle = value.customTitle
        }
        normalize()
    }
```

This deliberately leaves each live `NavTab.history`, `cachedTitle`, `cachedType`, active selection, and current collapse state untouched.

- [ ] **Step 4: Add inverse registration and the undoable workspace mutation helper**

In `AppModel`, add:

```swift
    @ObservationIgnored weak var undoManager: UndoManager?

    private func registerSidebarUndo(_ state: WorkspaceSidebarState, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restoreSidebarState(state, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restoreSidebarState(_ state: WorkspaceSidebarState, actionName: String) {
        guard var workspace else { return }
        let redo = workspace.sidebarState
        let previousPinnedContext = isPinnedListContext
        workspace.restoreSidebarState(state)
        self.workspace = workspace
        registerSidebarUndo(redo, actionName: actionName)
        if previousPinnedContext != isPinnedListContext {
            applyActiveListContext(from: previousPinnedContext)
        }
    }

    private func mutateSidebarWorkspace(actionName: String,
                                        _ body: (inout Workspace) -> Void) {
        guard var workspace else { return }
        let before = workspace.sidebarState
        body(&workspace)
        workspace.flattenTemporaryTabs()
        guard workspace.sidebarState != before else { return }
        self.workspace = workspace.isEmpty ? nil : workspace
        registerSidebarUndo(before, actionName: actionName)
    }
```

Do not alter the existing `mutateWorkspace`; navigation and collapse continue through that non-undo helper.

- [ ] **Step 5: Route in-scope page-tree intents through the helper**

Change only these public sidebar-edit methods to call `mutateSidebarWorkspace(actionName:_:)`:

- `setPinned` / `togglePin`: `String(localized: pinned ? "固定页面" : "取消固定")`.
- `groupTabs`, `groupTab`: `String(localized: "创建页面组")`.
- `moveTab`, `moveTabToRoot`, every `moveTabs*`, `moveItems*`, and every `moveGroup*`: `String(localized: "移动页面")`.
- `setTabOrder`: `String(localized: "移动页面")`.
- `renameTab`, `renameTabGroup`: `String(localized: "重命名")`.

Keep `toggleTabGroup` and `setTabGroup(_:collapsed:)` on the original `mutateWorkspace` path. Keep `groupTabs`' pin-and-group body from Task 3 inside one call to `mutateSidebarWorkspace`; do not reintroduce a separate `setPinned` call.

The outline view already invokes all synchronous mutations for one drag inside one AppKit event. Foundation's event grouping therefore combines a pin-plus-move drag into one undo item; the model does not need a second grouping layer.

- [ ] **Step 6: Cover cross-Space move ownership with a two-workspace state, not full model snapshots**

Add a file-private `AppModel` record:

```swift
    private struct SpaceSidebarState {
        let id: WorkspaceSpace.ID
        let workspace: Workspace?
    }
```

For the two cross-Space `moveItems` overloads, capture only the source and destination `Workspace` values before the transfer, then register one inverse that restores those two slots while preserving current tab histories by ID:

```swift
        let affectedIDs = Set([sourceSpaceID, destinationID])
        let before = spaces.filter { affectedIDs.contains($0.id) }
            .map { SpaceSidebarState(id: $0.id, workspace: $0.workspace) }
```

Take this capture after validating `destinationID` and before extracting the source bundle. After the existing `guard !bundle.tabs.isEmpty` and destination insertion succeed, call:

```swift
        registerSpaceSidebarUndo(before, actionName: String(localized: "移动页面"))
```

The restore/inverse pair is:

```swift
    private func restoreSpaceSidebarStates(_ old: [SpaceSidebarState], actionName: String) {
        let ids = Set(old.map(\.id))
        let redo = spaces.filter { ids.contains($0.id) }
            .map { SpaceSidebarState(id: $0.id, workspace: $0.workspace) }
        let liveTabs = Dictionary(
            spaces.filter { ids.contains($0.id) }
                .flatMap { $0.workspace?.tabs ?? [] }
                .map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current })

        for state in old {
            guard let index = spaces.firstIndex(where: { $0.id == state.id }) else { continue }
            spaces[index].workspace = state.workspace?.replacingTabValues(from: liveTabs)
            if spaces[index].workspace == nil { spaces[index].isBrowsing = true }
        }
        registerSpaceSidebarUndo(redo, actionName: actionName)
    }

    private func registerSpaceSidebarUndo(_ states: [SpaceSidebarState],
                                          actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restoreSpaceSidebarStates(states, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }
```

Add this narrow `Workspace` helper; it preserves current histories for every ID still present in either affected Space and uses the captured value only for an ID that is temporarily absent:

```swift
    public func replacingTabValues(from liveTabs: [NavTab.ID: NavTab]) -> Workspace {
        var copy = self
        for index in copy.tabs.indices {
            if let live = liveTabs[copy.tabs[index].id] { copy.tabs[index] = live }
        }
        copy.normalize()
        return copy
    }
```

Register the captured pair once per cross-Space method after both mutations succeed. Do not capture `spaces` wholesale and do not make Space creation/archive/delete undoable.

- [ ] **Step 7: Vend one session-scoped undo manager from the window**

In `MarpleWindowController` add:

```swift
    private let sidebarUndoManager = UndoManager()

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        sidebarUndoManager
    }
```

At the start of a successful `boot(paths:)`, before publishing `ActiveModel.current`, clear old actions and attach the manager:

```swift
        sidebarUndoManager.removeAllActions()
        model.undoManager = sidebarUndoManager
```

The standard Edit menu now supplies Command-Z and Shift-Command-Z; do not add parallel key commands.

- [ ] **Step 8: Add only the missing action-name translations**

Add these source-language entries to `Localizable.xcstrings` with the exact English values:

```text
创建页面组 = Create Page Group
移动页面 = Move Pages
```

Reuse existing `固定页面`, `取消固定`, and `重命名` entries for the remaining ordinary structure actions.

- [ ] **Step 9: Run ordinary undo tests and all navigation tests**

Run:

```bash
cd apple
swift test --filter SidebarUndoTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --filter WorkspaceTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --filter NavigationContextTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: all pass. The ordinary undo tests prove one group action consumes one undo, redo works, navigation history survives tree undo, and collapse changes never enter or get rewound by the stack.

- [ ] **Step 10: Commit ordinary sidebar undo**

```bash
git add apple/Sources/MarpleKit/Nav/Navigation.swift apple/Sources/Marple/App/AppModel.swift apple/Sources/Marple/App/MarpleWindowController.swift apple/Sources/Marple/Resources/Localizable.xcstrings apple/Tests/MarpleKitTests/SidebarUndoTests.swift
git commit -m "feat: add undo for sidebar structure edits"
```

### Task 5: Restore Closed Pages Exactly Without Rewinding Survivors

**Files:**
- Modify: `apple/Sources/MarpleKit/Nav/Navigation.swift:177-230, 350-380, 510-535`
- Modify: `apple/Sources/Marple/App/AppModel.swift:1380-1450`
- Modify: `apple/Tests/MarpleKitTests/SidebarUndoTests.swift`

**Interfaces:**
- Produces: `public struct WorkspaceCloseRecord: Sendable` with removed `NavTab` values, former root, and `reactivateID`.
- Produces: `Workspace.closeRecord(for:)` and `Workspace.restoreClosedTabs(from:)`.
- Produces: one inverse pair in `AppModel`: close IDs ↔ restore `WorkspaceCloseRecord`.

- [ ] **Step 1: Add failing single-close exact-restoration test**

Append:

```swift
    @MainActor
    @Test func undoCloseRestoresPlacementHistoryContextAndActiveTab() async throws {
        let (model, ids) = try await modelWithThreeTabs()
        model.setPinned([ids[0], ids[1]], to: true)
        model.groupTabs([ids[0], ids[1]])
        await model.selectTab(ids[1])
        await model.open("papers/later.md")
        let closed = try #require(model.tabs.first { $0.id == ids[1] })
        let groupID = try #require(model.tabGroup(containing: ids[1])?.id)
        let manager = attachUndoManager(to: model)

        await grouped(manager) { await model.closeTab(ids[1]) }
        #expect(!model.tabs.contains { $0.id == ids[1] })
        manager.undo()

        let restored = try #require(model.tabs.first { $0.id == ids[1] })
        #expect(restored.history == closed.history)
        #expect(restored.location.listContext == closed.location.listContext)
        #expect(model.tabGroup(containing: ids[1])?.id == groupID)
        #expect(model.activeTabID == ids[1])

        manager.redo()
        #expect(!model.tabs.contains { $0.id == ids[1] })
    }
```

Before attaching the manager, the setup mutations intentionally stay outside the close undo stack.

- [ ] **Step 2: Add failing batch-close and surviving-history test**

Append:

```swift
    @MainActor
    @Test func undoBatchCloseIsOneStepAndPreservesSurvivingHistory() async throws {
        let (model, ids) = try await modelWithThreeTabs()
        let manager = attachUndoManager(to: model)
        await grouped(manager) { await model.closeTabs(Set([ids[0], ids[1]])) }
        #expect(model.tabs.map(\.id) == [ids[2]])

        await model.open("papers/later.md")
        let survivor = try #require(model.tabs.first { $0.id == ids[2] }?.history)
        manager.undo()

        #expect(model.tabs.map(\.id) == ids)
        #expect(model.tabs.first { $0.id == ids[2] }?.history == survivor)
        #expect(!manager.canUndo)
        #expect(manager.canRedo)
    }

    @MainActor
    @Test func undoClosingLastPageRecreatesTheWorkspace() async throws {
        let only = sidebarEntry("papers/only.md")
        let model = AppModel(client: StubVaultClient(
            entries: [only], texts: [only.path: "# Only"]))
        await model.loadIndex()
        await model.open(only.path)
        let id = try #require(model.activeTabID)
        let manager = attachUndoManager(to: model)

        await grouped(manager) { await model.closeTab(id) }
        #expect(model.tabs.isEmpty)
        manager.undo()

        #expect(model.tabs.map(\.id) == [id])
        #expect(model.activeTabID == id)
        #expect(model.openPath == only.path)
    }

    @MainActor
    @Test func undoCloseOthersRestoresClosedActiveAndRedoKeepsRequestedPage() async throws {
        let (model, ids) = try await modelWithThreeTabs()
        model.setPinned([ids[0]], to: true)
        let manager = attachUndoManager(to: model)

        await grouped(manager) { await model.closeOtherTabs(ids[1]) }
        #expect(model.tabs.map(\.id) == [ids[0], ids[1]])
        #expect(model.activeTabID == ids[1])

        manager.undo()
        #expect(model.tabs.map(\.id) == ids)
        #expect(model.activeTabID == ids[2])

        manager.redo()
        #expect(model.tabs.map(\.id) == [ids[0], ids[1]])
        #expect(model.activeTabID == ids[1])
    }
```

- [ ] **Step 3: Run close tests and verify no inverse is registered**

Run:

```bash
cd apple
swift test --filter SidebarUndoTests.undoClose -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --filter SidebarUndoTests.undoBatchClose -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: close tests fail because closed tabs cannot be restored and `manager.canUndo` is false.

- [ ] **Step 4: Add the dedicated close record in `Navigation.swift`**

Add:

```swift
public struct WorkspaceCloseRecord: Sendable {
    fileprivate var closedTabs: [NavTab]
    fileprivate var formerRoot: [TabNode]
    fileprivate var reactivateID: NavTab.ID?

    public var tabIDs: Set<NavTab.ID> { Set(closedTabs.map(\.id)) }
}
```

Add to `Workspace`:

```swift
    public func closeRecord(for ids: Set<NavTab.ID>) -> WorkspaceCloseRecord? {
        let closed = tabs.filter { ids.contains($0.id) }
        guard !closed.isEmpty else { return nil }
        return WorkspaceCloseRecord(
            closedTabs: closed,
            formerRoot: root,
            reactivateID: closed.contains(where: { $0.id == activeID }) ? activeID : nil)
    }

    public mutating func restoreClosedTabs(from record: WorkspaceCloseRecord) {
        let currentByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let closedByID = Dictionary(uniqueKeysWithValues: record.closedTabs.map { ($0.id, $0) })
        let formerIDs = Set(Self.leafIDs(record.formerRoot))
        let collapsed = Dictionary(uniqueKeysWithValues: tabGroups.map { ($0.id, $0.isCollapsed) })
        func preservingCollapse(_ nodes: [TabNode]) -> [TabNode] {
            nodes.map { node in
                guard case .group(var group) = node else { return node }
                group.isCollapsed = collapsed[group.id] ?? group.isCollapsed
                group.children = preservingCollapse(group.children)
                return .group(group)
            }
        }
        let extraRoot = Self.filterNodes(root, keeping: { !formerIDs.contains($0) })
        root = preservingCollapse(record.formerRoot) + extraRoot

        let order = Self.leafIDs(root)
        tabs = order.compactMap { currentByID[$0] ?? closedByID[$0] }
        if let reactivateID = record.reactivateID { activeID = reactivateID }
        else if !tabs.contains(where: { $0.id == activeID }), let first = tabs.first { activeID = first.id }
        normalize()
    }

    public init?(restoring record: WorkspaceCloseRecord) {
        guard let first = record.closedTabs.first else { return nil }
        tabs = record.closedTabs
        activeID = record.reactivateID ?? first.id
        root = Self.filterNodes(record.formerRoot, keeping: { record.tabIDs.contains($0) })
        normalize()
    }
```

Implement the private recursive `filterNodes(_:keeping:)` directly beside existing tree helpers. It must retain a group only when at least one filtered child remains, retain the group's existing ID/name/collapse value, and retain a tab only when the predicate returns true:

```swift
    private static func filterNodes(_ nodes: [TabNode],
                                    keeping keep: (NavTab.ID) -> Bool) -> [TabNode] {
        nodes.compactMap { node in
            switch node {
            case .tab(let id):
                return keep(id) ? node : nil
            case .group(var group):
                group.children = filterNodes(group.children, keeping: keep)
                return group.children.isEmpty ? nil : .group(group)
            }
        }
    }
```

Use `Self.filterNodes(root, keeping: { !formerIDs.contains($0) })` at the call site. This preserves pages opened after the close without restoring unrelated state.

- [ ] **Step 5: Register close and restore as inverse operations in `AppModel`**

Add:

```swift
    private func registerCloseUndo(_ record: WorkspaceCloseRecord, actionName: String,
                                   selectAfterClose: NavTab.ID?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restoreClosedTabs(record, actionName: actionName,
                                        selectAfterClose: selectAfterClose)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restoreClosedTabs(_ record: WorkspaceCloseRecord, actionName: String,
                                   selectAfterClose: NavTab.ID?) {
        let previousPinnedContext = isPinnedListContext
        if workspace == nil {
            workspace = Workspace(restoring: record)
        } else {
            workspace?.restoreClosedTabs(from: record)
        }
        isBrowsing = false
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let sync = model.closeTabsNow(record.tabIDs, actionName: actionName,
                                              selectAfterClose: selectAfterClose)
                if let sync, sync.activeChanged {
                    Task { await model.syncToActiveLocation(from: sync.previousPinnedContext) }
                }
            }
        }
        undoManager?.setActionName(actionName)
        applyActiveListContext(from: previousPinnedContext)
        Task { await syncToActiveLocation(from: previousPinnedContext) }
    }
```

Update `registerCloseUndo` to accept `selectAfterClose` and pass it to `restoreClosedTabs`. Then factor the existing three close entry points through one synchronous mutation helper so undo/redo registration stays inside Foundation's active undo group:

```swift
    private func closeTabsNow(_ ids: Set<NavTab.ID>, actionName: String,
                              selectAfterClose: NavTab.ID? = nil)
        -> (previousPinnedContext: Bool, activeChanged: Bool)? {
        guard var workspace, let record = workspace.closeRecord(for: ids) else { return nil }
        let previousActiveID = activeTabID
        let previousPinnedContext = isPinnedListContext
        for id in ids { workspace.closeTab(id) }
        if let selectAfterClose { workspace.select(selectAfterClose) }
        self.workspace = workspace.isEmpty ? nil : workspace
        if self.workspace == nil { isBrowsing = true }
        registerCloseUndo(record, actionName: actionName,
                          selectAfterClose: selectAfterClose)
        return (previousPinnedContext, activeTabID != previousActiveID)
    }
```

Route:

- `closeTab(_:)` to `{ id }`, action `String(localized: "关闭页面")`; a direct close remains allowed for a pinned page.
- `closeOtherTabs(_:)` to its precomputed unpinned ID set, action `String(localized: "关闭其他页面")`, with `selectAfterClose: keep`.
- `closeTabs(_:)` to its precomputed set of matching unpinned IDs, action `String(localized: "关闭页面")`.
- `closeActiveTab()` through `closeTab(_:)`, preserving its pinned guard.

Each async public wrapper awaits `syncToActiveLocation(from:)` only when the helper reports `activeChanged`. The redo closure above schedules that same sync after registering the next inverse synchronously.

Do not use `WorkspaceSidebarState` for close; the dedicated record is what restores full histories and contexts for removed tabs.

- [ ] **Step 6: Run every close and sidebar undo test**

Run:

```bash
cd apple
swift test --filter SidebarUndoTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --filter WorkspaceTests.close -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: single, batch, and last-page close undo/redo pass; the surviving tab retains its later history; existing pinned-close guards remain green.

- [ ] **Step 7: Commit close undo**

```bash
git add apple/Sources/MarpleKit/Nav/Navigation.swift apple/Sources/Marple/App/AppModel.swift apple/Tests/MarpleKitTests/SidebarUndoTests.swift
git commit -m "feat: restore closed pages through undo"
```

### Task 6: Undo Type and Saved-View Configuration, Then Build for Testing

**Files:**
- Modify: `apple/Sources/Marple/App/AppModel.swift:585-635, 1015-1055`
- Modify: `apple/Sources/Marple/Resources/Localizable.xcstrings`
- Modify: `apple/Tests/MarpleKitTests/SidebarUndoTests.swift`

**Interfaces:**
- Produces: narrow inverse registration for `typeOrder`, `hiddenTypes`, and `[SavedView]`.
- Leaves: saved-view creation, saved-view filter/sort editing, pane selection, and Space operations outside this undo scope.

- [ ] **Step 1: Add failing type and saved-view undo tests**

Append:

```swift
    @MainActor
    @Test func typeOrderAndVisibilityUndoIndependently() {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let manager = attachUndoManager(to: model)
        let originalOrder = model.typeOrder
        let movedOrder = Array(originalOrder.dropFirst()) + [originalOrder[0]]

        grouped(manager) { model.setTypeOrder(movedOrder) }
        #expect(model.typeOrder == movedOrder)
        manager.undo()
        #expect(model.typeOrder == originalOrder)
        manager.redo()
        #expect(model.typeOrder == movedOrder)

        manager.removeAllActions()
        let type = movedOrder[0]
        let wasHidden = model.hiddenTypes.contains(type)
        grouped(manager) { model.setTypeHidden(type, hidden: !wasHidden) }
        #expect(model.hiddenTypes.contains(type) == !wasHidden)
        manager.undo()
        #expect(model.hiddenTypes.contains(type) == wasHidden)

        manager.removeAllActions()
        model.setTypeOrder(originalOrder)
        model.setTypeHidden(type, hidden: wasHidden)
    }

    @MainActor
    @Test func savedViewMoveRenameAndDeleteEachUndo() throws {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let first = model.createSavedView(named: "First")
        let second = model.createSavedView(named: "Second")
        let manager = attachUndoManager(to: model)

        var moved = false
        grouped(manager) { moved = model.moveSavedView(first.id, to: 2) }
        #expect(moved)
        #expect(model.savedViews.map(\.id) == [second.id, first.id])
        manager.undo()
        #expect(model.savedViews.map(\.id) == [first.id, second.id])

        manager.removeAllActions()
        grouped(manager) { model.renameSavedView(first.id, to: "Renamed") }
        manager.undo()
        #expect(model.savedView(first.id)?.name == "First")

        manager.removeAllActions()
        grouped(manager) { model.deleteSavedView(first.id) }
        #expect(model.savedView(first.id) == nil)
        manager.undo()
        #expect(model.savedViews.map(\.id) == [first.id, second.id])
    }
```

- [ ] **Step 2: Run the tests and verify collection edits are not undoable**

Run:

```bash
cd apple
swift test --filter SidebarUndoTests.typeOrderAndVisibilityUndoIndependently -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --filter SidebarUndoTests.savedViewMoveRenameAndDeleteEachUndo -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: assertions after `undo()` fail because the edited collections remain changed.

- [ ] **Step 3: Add narrow inverse helpers for type configuration**

Add:

```swift
    private func registerTypeOrderUndo(_ old: [EntryType], actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let redo = model.typeOrder
                model.typeOrder = old
                model.registerTypeOrderUndo(redo, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func registerHiddenTypesUndo(_ old: Set<EntryType>, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restoreHiddenTypes(old, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restoreHiddenTypes(_ old: Set<EntryType>, actionName: String) {
        let redo = hiddenTypes
        hiddenTypes = old
        if case .type(let current) = browsePane, hiddenTypes.contains(current),
           let first = visibleTypeOrder.first {
            select(pane: .type(first))
        }
        registerHiddenTypesUndo(redo, actionName: actionName)
    }
```

In `setTypeOrder`, guard against equality, capture `old`, assign, and register `String(localized: "调整物件顺序")`. In `setTypeHidden`, return early when the membership already equals `hidden`, capture `old`, retain the existing selected-pane fallback, then register `String(localized: "隐藏或显示物件")`.

- [ ] **Step 4: Add one inverse helper for saved-view order/name/deletion**

Add:

```swift
    private func registerSavedViewsUndo(_ old: [SavedView], actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restoreSavedViews(old, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restoreSavedViews(_ old: [SavedView], actionName: String) {
        let redo = savedViews
        savedViews = old
        if case .savedView(let id) = browsePane, savedView(id) == nil {
            select(pane: .type(visibleTypeOrder.first ?? .paper))
        }
        registerSavedViewsUndo(redo, actionName: actionName)
    }
```

Capture/register only after an effective change in:

- `renameSavedView`: `String(localized: "重命名")`.
- `deleteSavedView`: `String(localized: "删除视图")`; retain the current fallback pane behavior, and do not make pane selection part of the inverse.
- `moveSavedView`: `String(localized: "移动视图")`; preserve its existing `Bool` result and drop-index math.

Do not register `createSavedView`, `setFilters`, or `setSort` as sidebar structure undo.

- [ ] **Step 5: Add the remaining localized action names**

Add exact English values:

```text
调整物件顺序 = Reorder Objects
隐藏或显示物件 = Hide or Show Object
移动视图 = Move View
```

- [ ] **Step 6: Run all focused suites**

Run:

```bash
cd apple
swift test --filter SidebarUndoTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --filter NavigationContextTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --filter DomainCodableTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --filter WorkspaceTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: every focused suite passes with no new warnings attributable to these changes.

- [ ] **Step 7: Run the complete Swift test suite**

Run:

```bash
cd apple
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: the complete suite passes. Record any pre-existing warnings separately; do not clean them up in this hotfix.

- [ ] **Step 8: Build the development app and inspect its signature**

Run:

```bash
cd apple
make build
codesign --verify --deep --strict "$HOME/Library/Caches/marple-dev/Marple.app"
```

Expected: `make build` completes and the generated app bundle passes the repository's development-signing verification path. If the development bundle is intentionally unsigned on this machine, record that exact `codesign` result and verify the executable launches through `make run` instead of changing signing configuration.

- [ ] **Step 9: Launch and manually smoke-test the six AppKit behaviors**

Run:

```bash
cd apple
make run
```

Verify in the launched app:

1. Unpin every fixed page, then drag one temporary page and an ordered multi-selection into the empty `固定页面`; both drops succeed and preserve order.
2. Fixed page rows and fixed groups show no trailing pin glyph; context-menu unpin and drag-to-`页面` still work.
3. Right-click two or more temporary page rows; `把这 N 个合成一个新组` appears, and invoking it pins them and creates the group above.
4. Give two temporary pages different pane/search/filter-match/filter/sort scenes; switching between them restores each list, selects the open entry, and scrolls it into view. Edit a named view between visits and confirm its page uses the latest definition.
5. Exercise pin, unpin, drag reorder/group, rename, close one, close others, batch close, object reorder/hide, and view reorder/rename/delete. Command-Z restores one gesture at a time; Shift-Command-Z reapplies it. Undo close restores the exact page/group/history/active location.
6. Expand/collapse sections and groups and navigate within a surviving page; neither action creates an undo item, and a later structure undo does not rewind them.

- [ ] **Step 10: Commit the final undo scope and report the testable app path**

```bash
git add apple/Sources/Marple/App/AppModel.swift apple/Sources/Marple/Resources/Localizable.xcstrings apple/Tests/MarpleKitTests/SidebarUndoTests.swift
git commit -m "feat: complete sidebar undo coverage"
git status --short --branch
```

Expected: the worktree is clean, `main` contains the task commits, and the testable app is at `$HOME/Library/Caches/marple-dev/Marple.app`.
