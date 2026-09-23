import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@Suite @MainActor
struct CLIOrganizationTests {
    @Test func listReturnsCurrentSpaceTreeWithUsableIDs() async throws {
        let model = await fixture()
        let ids = model.tabs.map(\.id)
        model.groupTabs([ids[0], ids[1]])
        let group = try #require(model.tabGroups.first)
        model.renameTabGroup(group.id, to: "Research")
        let response = try await request("tabs.list", model: model)
        #expect(response.ok)
        let data = try payload(response)
        let tree = try #require(data["tree"] as? [[String: Any]])
        #expect(tree.count == 2)
        #expect(tree[0]["kind"] as? String == "folder")
        #expect(tree[0]["id"] as? String == group.id.uuidString)
        #expect(tree[0]["title"] as? String == "Research")
        let children = try #require(tree[0]["children"] as? [[String: Any]])
        #expect(children.compactMap { $0["id"] as? String } == ids.prefix(2).map(\.uuidString))
        #expect(children[0]["path"] as? String == "notes/a.md")
        #expect(children[0]["pinned"] as? Bool == true)
        #expect(tree[1]["pinned"] as? Bool == false)
        #expect(data["spaceID"] as? String == model.activeSpaceID?.uuidString)
        #expect(data["activeTabID"] as? String == ids[2].uuidString)
    }

    @Test func renameAndResetKeepDocumentIdentityAndHistory() async throws {
        let model = await fixture()
        let tab = model.tabs[0]
        let response = try await request("tabs.rename", ["id": tab.id.uuidString, "title": "  新标题  "], model: model)
        #expect(response.ok)
        #expect(model.tabs[0].customTitle == "新标题")
        #expect(model.tabs[0].history == tab.history)
        #expect(model.tabs[0].location == tab.location)
        let reset = try await request("tabs.rename", ["id": tab.id.uuidString, "reset": true], model: model)
        #expect(reset.ok)
        #expect(model.tabs[0].customTitle == nil)
        #expect(model.tabTitle(model.tabs[0]) == "A")
    }

    @Test func batchMovePreservesInputOrderAroundTemporaryAnchor() async throws {
        let model = await fixture()
        let ids = model.tabs.map(\.id)
        let response = try await request("tabs.move", ["ids": [ids[2], ids[0]].map(\.uuidString), "after": ids[1].uuidString], model: model)
        #expect(response.ok)
        #expect(model.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(model.tabs.allSatisfy { !$0.pinned })
        #expect(model.activeTabID == ids[2])
        let before = try await request("tabs.move", ["ids": [ids[0].uuidString], "before": ids[1].uuidString], model: model)
        #expect(before.ok)
        #expect(model.tabs.map(\.id) == [ids[0], ids[1], ids[2]])
    }

    @Test func movePinnedTabBesideTemporaryTabUnpinsAndUndoRestoresFolder() async throws {
        let model = await fixture()
        let ids = model.tabs.map(\.id)
        let folder = try await create("Pinned", items: [ids[0]], model: model)
        await model.selectTab(ids[0])
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        undo.beginUndoGrouping()
        let moved = try await request("tabs.move", ["ids": [ids[0].uuidString], "after": ids[1].uuidString], model: model)
        undo.endUndoGrouping()
        #expect(moved.ok)
        #expect(model.temporaryTabs.map(\.id) == [ids[1], ids[0], ids[2]])
        #expect(model.tabs.first { $0.id == ids[0] }?.pinnedLocation == nil)
        #expect(model.workspace?.group(folder)?.children.isEmpty == true)
        #expect(!model.isPinnedListContext)
        undo.undo()
        #expect(model.tabs(in: folder).map(\.id) == [ids[0]])
        #expect(model.tabs(in: folder).first?.pinned == true)
        #expect(model.isPinnedListContext)
    }

    @Test func listDistinguishesPinnedIdentityFromCurrentReadingPath() async throws {
        let model = await fixture()
        let id = model.tabs[0].id
        model.setPinned([id], to: true)
        await model.selectTab(id)
        await model.open("notes/b.md")
        let response = try await request("tabs.list", model: model)
        let node = try #require(response.data?.tree?.first)
        #expect(node.id == id)
        #expect(node.path == "notes/a.md")
        #expect(node.currentPath == "notes/b.md")
        #expect(node.title == "A")
    }

    @Test func undoAfterSwitchingSpacesEditsOnlyOriginalSpace() async throws {
        let model = await fixture()
        let id = model.tabs[0].id
        let originalSpace = try #require(model.activeSpaceID)
        model.addSpace()
        model.createFolder()
        let otherSpace = try #require(model.activeSpaceID)
        let otherState = model.workspace?.sidebarState
        await model.selectSpace(originalSpace)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        undo.beginUndoGrouping()
        let response = try await request("tabs.rename", ["id": id.uuidString, "title": "Renamed"], model: model)
        undo.endUndoGrouping()
        #expect(response.ok)
        await model.selectSpace(otherSpace)
        undo.undo()
        #expect(model.spaces.first { $0.id == originalSpace }?.workspace?.tabs.first?.customTitle == nil)
        #expect(model.workspace?.sidebarState == otherState)
        #expect(model.activeSpaceID == otherSpace)
        undo.redo()
        #expect(model.spaces.first { $0.id == originalSpace }?.workspace?.tabs.first?.customTitle == "Renamed")
        #expect(model.workspace?.sidebarState == otherState)
    }

    @Test func createNestedFoldersPinsItemsAndDissolvePromotesChildren() async throws {
        let model = await fixture()
        let ids = model.tabs.map(\.id)
        let outer = try await create("Outer", items: [ids[1], ids[0]], model: model)
        #expect(model.tabs(in: outer).map(\.id) == [ids[1], ids[0]])
        #expect(model.tabs(in: outer).allSatisfy { $0.pinned })
        let inner = try await create("Inner", items: [ids[2]], parent: outer, model: model)
        #expect(model.workspace?.group(inner, isInsideSubtreeOf: outer) == true)
        #expect(model.tabs(in: inner).map(\.id) == [ids[2]])
        #expect(model.pendingFolderRenameID == nil)
        let renamed = try await request("folders.rename", ["id": inner.uuidString, "title": "Nested"], model: model)
        #expect(renamed.ok)
        #expect(model.workspace?.group(inner)?.name == "Nested")
        let moved = try await request("folders.move", ["ids": [inner.uuidString], "before": ids[1].uuidString], model: model)
        #expect(moved.ok)
        #expect(model.tabs.map(\.id) == [ids[2], ids[1], ids[0]])
        let dissolved = try await request("folders.dissolve", ["id": outer.uuidString], model: model)
        #expect(dissolved.ok)
        #expect(model.tabRootNodes.map(nodeID) == [inner, ids[1], ids[0]])
        #expect(model.tabs.count == 3)
    }

    @Test func moveIntoFolderAndBackToRootKeepsEmptyFolder() async throws {
        let model = await fixture()
        let id = model.tabs[0].id
        let folder = try await create("Empty", model: model)
        let moved = try await request("tabs.move", ["ids": [id.uuidString], "parent": folder.uuidString], model: model)
        #expect(moved.ok)
        #expect(model.tabs(in: folder).map(\.id) == [id])
        #expect(model.tabs(in: folder).first?.pinned == true)
        let root = try await request("tabs.move", ["ids": [id.uuidString], "root": true], model: model)
        #expect(root.ok)
        #expect(model.tabRootNodes.contains(.tab(id)))
        #expect(model.workspace?.group(folder)?.children.isEmpty == true)
    }

    @Test func mixedSelectionMovesAncestorOnceAndNestsFolders() async throws {
        let model = await fixture()
        let ids = model.tabs.map(\.id)
        let child = try await create("Child", items: [ids[0]], model: model)
        let parent = try await create("Parent", items: [child, ids[0], ids[1]], model: model)
        #expect(model.workspace?.group(parent)?.children.map(nodeID) == [child, ids[1]])
        #expect(model.tabs(in: child).map(\.id) == [ids[0]])
        let destination = try await create("Destination", model: model)
        let nested = try await request("folders.move", ["ids": [parent.uuidString], "parent": destination.uuidString], model: model)
        #expect(nested.ok)
        #expect(model.workspace?.group(child, isInsideSubtreeOf: destination) == true)
        let root = try await request("folders.move", ["ids": [parent.uuidString], "root": true], model: model)
        #expect(root.ok)
        #expect(model.tabRootNodes.map(nodeID).contains(parent))
        #expect(model.workspace?.group(destination)?.children.isEmpty == true)
    }

    @Test func folderBatchReordersBesideFolderWithoutChangingContents() async throws {
        let model = await fixture()
        let ids = model.tabs.map(\.id)
        let a = try await create("A", items: [ids[0]], model: model)
        let b = try await create("B", items: [ids[1]], model: model)
        let c = try await create("C", items: [ids[2]], model: model)
        let moved = try await request("folders.move", ["ids": [c, a].map(\.uuidString), "after": b.uuidString], model: model)
        #expect(moved.ok)
        #expect(model.tabRootNodes.map(nodeID) == [b, c, a])
        #expect(model.tabs(in: a).map(\.id) == [ids[0]])
        #expect(model.tabs(in: b).map(\.id) == [ids[1]])
        #expect(model.tabs(in: c).map(\.id) == [ids[2]])
    }

    @Test func invalidRequestsLeaveWholeWorkspaceUnchanged() async throws {
        let model = await fixture()
        let ids = model.tabs.map(\.id)
        let outer = try await create("Outer", items: [ids[0]], model: model)
        let inner = try await create("Inner", parent: outer, model: model)
        let before = try #require(model.workspace?.sidebarState)
        let cases: [(String, [String: Any], String)] = [
            ("tabs.rename", ["id": ids[0].uuidString, "title": "  "], "bad_request"),
            ("tabs.rename", ["id": ids[0].uuidString, "title": "X", "reset": true], "bad_request"),
            ("tabs.rename", ["id": "invalid", "title": "X"], "bad_request"),
            ("folders.rename", ["id": ids[0].uuidString, "title": "X"], "bad_request"),
            ("tabs.move", ["ids": [ids[1].uuidString, UUID().uuidString], "parent": outer.uuidString], "not_found"),
            ("tabs.move", ["ids": [ids[1].uuidString], "parent": UUID().uuidString], "not_found"),
            ("tabs.move", ["ids": [ids[1].uuidString]], "bad_request"),
            ("tabs.move", ["ids": [ids[1].uuidString], "before": ids[0].uuidString, "root": true], "bad_request"),
            ("tabs.move", ["ids": [ids[1].uuidString], "before": ids[1].uuidString], "bad_request"),
            ("folders.move", ["ids": [outer.uuidString], "parent": inner.uuidString], "bad_request"),
            ("folders.move", ["ids": [outer.uuidString], "parent": outer.uuidString], "bad_request"),
            ("folders.move", ["ids": [outer.uuidString], "before": ids[0].uuidString], "bad_request"),
            ("folders.move", ["ids": [outer.uuidString], "after": ids[1].uuidString], "bad_request"),
            ("folders.create", ["title": "Cycle", "ids": [outer.uuidString], "parent": inner.uuidString], "bad_request"),
            ("folders.create", ["title": "Empty", "parent": ids[0].uuidString], "bad_request"),
        ]
        for (method, fields, code) in cases {
            let response = try await request(method, fields, model: model)
            #expect(!response.ok, Comment(rawValue: method))
            #expect(response.error?.code == code, Comment(rawValue: "\(method) \(fields)"))
            #expect(model.workspace?.sidebarState == before)
        }
    }

    @Test func editsAreOneUndoStepAndRestoreAfterRestart() async throws {
        let suite = "cli-organization-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        let model = await fixture(store: store)
        let ids = model.tabs.map(\.id)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        undo.beginUndoGrouping()
        let folder = try await create("Research", items: [ids[1], ids[0]], model: model)
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        undo.undo()
        #expect(model.tabGroups.isEmpty)
        #expect(model.tabs.map(\.id) == ids)
        #expect(model.tabs.allSatisfy { !$0.pinned })
        #expect(!undo.canUndo)
        undo.redo()
        #expect(model.tabs(in: folder).map(\.id) == [ids[1], ids[0]])
        undo.beginUndoGrouping()
        let renamed = try await request("tabs.rename", ["id": ids[1].uuidString, "title": "Renamed"], model: model)
        undo.endUndoGrouping()
        #expect(renamed.ok)
        undo.beginUndoGrouping()
        let inner = try await create("Inner", items: [ids[0]], parent: folder, model: model)
        undo.endUndoGrouping()
        #expect(model.workspace?.group(inner) != nil)
        let restored = await fixture(store: store, openTabs: false)
        let outer = try #require(restored.tabGroups.first { $0.name == "Research" })
        let nested = try #require(restored.tabGroups.first { $0.name == "Inner" })
        #expect(restored.workspace?.group(nested.id, isInsideSubtreeOf: outer.id) == true)
        #expect(restored.tabs.map(\.location.openPath) == ["notes/b.md", "notes/a.md", "notes/c.md"])
        #expect(restored.tabs.first?.customTitle == "Renamed")
        #expect(restored.tabs(in: nested.id).first?.pinned == true)
    }

    @Test func emptySpaceSupportsFolderCreationAndOtherSpacesStayUnchanged() async throws {
        let model = await fixture()
        let originalID = model.activeSpaceID
        let original = model.workspace?.sidebarState
        model.addSpace()
        let response = try await request("tabs.list", model: model)
        #expect(response.ok)
        #expect((try payload(response)["tree"] as? [Any])?.isEmpty == true)
        let folder = try await create("Only folder", model: model)
        #expect(model.tabGroups.map(\.id) == [folder])
        #expect(model.tabs.isEmpty)
        #expect(model.spaces.first { $0.id == originalID }?.workspace?.sidebarState == original)
    }

    private func fixture(store: StateStore? = nil, openTabs: Bool = true) async -> AppModel {
        let entries = zip(["a", "b", "c"], ["A", "B", "C"]).map { path, title in
            Entry(path: "notes/\(path).md", type: .note, title: title, author: [], year: nil,
                  ratingScore: 0, themes: [], preview: "", hasPDF: false)
        }
        let model = AppModel(client: StubVaultClient(entries: entries,
            texts: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, "# \($0.title!)") })), stateStore: store)
        await model.loadIndex()
        if openTabs {
            for entry in entries { await model.openInNewTab(entry.path) }
        }
        return model
    }

    private func request(_ method: String, _ fields: [String: Any] = [:], model: AppModel) async throws -> CLIResponse {
        var json = fields
        json["method"] = method
        let request = try JSONDecoder().decode(CLIRequest.self, from: JSONSerialization.data(withJSONObject: json))
        return await CLIHandlers.handle(request, model: model, indexer: VaultIndexer(workspaceRoot: "/tmp"))
    }

    private func payload(_ response: CLIResponse) throws -> [String: Any] {
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        return try #require(object["data"] as? [String: Any])
    }

    private func create(_ title: String, items: [UUID] = [], parent: UUID? = nil, model: AppModel) async throws -> UUID {
        var fields: [String: Any] = ["title": title, "ids": items.map(\.uuidString)]
        if let parent { fields["parent"] = parent.uuidString }
        let response = try await request("folders.create", fields, model: model)
        try #require(response.ok)
        let id = try #require(try payload(response)["createdID"] as? String)
        return try #require(UUID(uuidString: id))
    }

    private func nodeID(_ node: TabNode) -> UUID {
        switch node {
        case .tab(let id): return id
        case .group(let group): return group.id
        }
    }
}
