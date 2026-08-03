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
        #expect(model.tabs(in: group.id).allSatisfy { $0.pinned })
        #expect(model.pinnedTabRootNodes == [.group(group)])
        #expect(model.temporaryTabs.map(\.location.openPath) == [third.path])
    }

    @MainActor
    @Test func pinUndoAndRedoRestoreThePinnedState() async throws {
        let (model, ids) = try await modelWithThreeTabs()
        let manager = attachUndoManager(to: model)
        let anchor = try #require(model.tabs.first { $0.id == ids[0] }?.location)

        grouped(manager) { model.setPinned([ids[0]], to: true) }
        await model.selectTab(ids[0])
        await model.open("papers/later.md")

        manager.undo()
        let unpinned = try #require(model.tabs.first { $0.id == ids[0] })
        #expect(!unpinned.pinned)
        #expect(unpinned.pinnedLocation == nil)
        #expect(unpinned.location.openPath == "papers/later.md")
        #expect(manager.canRedo)

        manager.redo()
        let repinned = try #require(model.tabs.first { $0.id == ids[0] })
        #expect(repinned.pinned)
        #expect(repinned.pinnedLocation == anchor)
        #expect(repinned.location.openPath == "papers/later.md")
    }

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

    @MainActor
    @Test func undoCloseRestoresPlacementHistoryContextAndActiveTab() async throws {
        let (model, ids) = try await modelWithThreeTabs()
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
    @Test func undoClosePreservesAPageOpenedAfterward() async throws {
        let (model, ids) = try await modelWithThreeTabs()
        let manager = attachUndoManager(to: model)
        await grouped(manager) { await model.closeTab(ids[0]) }

        await model.openInNewTab("papers/later.md")
        let laterID = try #require(model.activeTabID)
        manager.undo()

        #expect(model.tabs.map(\.id) == ids + [laterID])
        #expect(model.activeTabID == laterID)
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
    @Test func typeOrderAndVisibilityUndoIndependently() throws {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let originalOrder = model.typeOrder
        let first = try #require(originalOrder.first)
        let movedOrder = Array(originalOrder.dropFirst()) + [first]
        let wasHidden = model.hiddenTypes.contains(first)
        defer {
            model.undoManager = nil
            model.setTypeOrder(originalOrder)
            model.setTypeHidden(first, hidden: wasHidden)
        }
        let manager = attachUndoManager(to: model)

        grouped(manager) { model.setTypeOrder(movedOrder) }
        #expect(model.typeOrder == movedOrder)
        manager.undo()
        #expect(model.typeOrder == originalOrder)
        manager.redo()
        #expect(model.typeOrder == movedOrder)

        manager.removeAllActions()
        grouped(manager) { model.setTypeHidden(first, hidden: !wasHidden) }
        #expect(model.hiddenTypes.contains(first) == !wasHidden)
        manager.undo()
        #expect(model.hiddenTypes.contains(first) == wasHidden)
    }

    @MainActor
    @Test func savedViewMoveRenameAndDeleteEachUndoWithoutRewindingDefinition() throws {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let first = model.createSavedView(named: "First")
        let second = model.createSavedView(named: "Second")
        let manager = attachUndoManager(to: model)

        var moved = false
        grouped(manager) { moved = model.moveSavedView(first.id, to: 2) }
        #expect(moved)
        #expect(model.savedViews.map(\.id) == [second.id, first.id])
        model.select(pane: .savedView(first.id))
        let latestClause = FilterClause(id: "latest", field: .year, op: .gte, value: "2020")
        model.setFilters([latestClause])
        manager.undo()
        #expect(model.savedViews.map(\.id) == [first.id, second.id])
        #expect(model.savedView(first.id)?.clauses == [latestClause])

        manager.removeAllActions()
        grouped(manager) { model.renameSavedView(first.id, to: "Renamed") }
        manager.undo()
        #expect(model.savedView(first.id)?.name == "First")

        manager.removeAllActions()
        grouped(manager) { model.deleteSavedView(first.id) }
        #expect(model.savedView(first.id) == nil)
        manager.undo()
        #expect(model.savedViews.map(\.id) == [first.id, second.id])
        model.select(pane: .savedView(first.id))
        manager.redo()
        #expect(model.savedView(first.id) == nil)
        if case .savedView = model.pane {
            Issue.record("Redoing saved-view deletion left a stale selected pane")
        }
    }
}

@MainActor
private func attachUndoManager(to model: AppModel) -> UndoManager {
    let manager = UndoManager()
    model.undoManager = manager
    return manager
}

@MainActor
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

private func sidebarEntry(_ path: String) -> Entry {
    Entry(path: path, type: .paper, title: path, author: [], year: nil,
          ratingScore: 0, themes: [], preview: "", hasPDF: false)
}
