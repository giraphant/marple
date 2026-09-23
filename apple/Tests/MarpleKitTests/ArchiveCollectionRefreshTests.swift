import AppKit
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor @Suite(.serialized)
struct ArchiveCollectionRefreshTests {
    @Test func moveUpdatesMountedTableWithoutChangingPane() async throws {
        _ = NSApplication.shared
        let (root, model, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = EntryTableView.Coordinator(model: model)
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? NSTableView)
        try await waitUntil { table.numberOfRows == 2 }
        let countColumn = try #require(table.tableColumns.first { $0.identifier.rawValue == "memberCount" })
        #expect(countColumn.isHidden)
        table.sortDescriptors = [NSSortDescriptor(key: "memberCount", ascending: false)]
        #expect(model.activeSortClauses.first?.field == .memberCount)
        let old = "vault/archives/a/archive.md"
        await model.open(old)
        _ = try await model.performArchiveCollection(.init(action: "move", paths: [old], destination: "vault/archives/group"))
        // No tab, pane or browse-mode toggle to force the view to reconstruct.
        try await waitUntil { table.numberOfRows == 1 }
        #expect(coordinator.dropEntry(at: 0)?.isArchiveCollection == true)
        #expect(!model.visibleEntries.contains { $0.path == old })
        #expect(model.archiveCollections.first?.members.count == 1)
        let grouped = "vault/archives/group/a/archive.md"
        _ = try await model.performArchiveCollection(.init(action: "move", paths: [grouped], destination: "vault/archives"))
        try await waitUntil { table.numberOfRows == 2 }
        #expect(model.visibleEntries.contains { $0.path == old })
        // Member count changes re-sort roots without leaving the current view.
        _ = try await model.performArchiveCollection(.init(action: "move", paths: [old], destination: "vault/archives/group"))
        try await waitUntil { coordinator.dropEntry(at: 0)?.isArchiveCollection == true }
    }

    @Test func expandsInPlaceAndRefreshesMembersWithoutNavigation() async throws {
        _ = NSApplication.shared
        let (root, model, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = EntryTableView.Coordinator(model: model)
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? BrowseTableView)
        let marker = "vault/archives/group/collection.md"
        let groupRow = try #require(model.visibleEntries.firstIndex { $0.path == marker })
        table.onClickRow?(groupRow)
        #expect(model.expandedArchiveCollections.contains("vault/archives/group"))
        #expect(model.openPath == nil)
        #expect(model.visibleEntries.count == 2) // Empty folder stays present.
        let old = "vault/archives/a/archive.md"
        _ = try await model.performArchiveCollection(.init(action: "move", paths: [old], destination: "vault/archives/group"))
        let moved = "vault/archives/group/a/archive.md"
        try await waitUntil { coordinator.dropEntry(at: 1)?.path == moved }
        #expect(model.visibleEntries.map(\.path) == [marker, moved])
        #expect(model.archiveMemberIndent(moved))
        #expect(model.visibleEntries.first?.author.isEmpty == true)
        #expect(model.visibleEntries.first?.added == nil)
        table.onClickRow?(0)
        try await waitUntil { table.numberOfRows == 1 }
        #expect(model.openPath == nil)
        table.onClickRow?(0)
        try await waitUntil { table.numberOfRows == 2 }
        _ = try await model.performArchiveCollection(.init(action: "rename", paths: ["vault/archives/group"], name: "renamed"))
        #expect(model.expandedArchiveCollections == ["vault/archives/renamed"])
        #expect(model.visibleEntries.count == 2)
    }

    @Test func alreadyReconciledMoveStillPublishesPendingIndex() async throws {
        let (root, model, indexer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = "vault/archives/a/archive.md"
        _ = try ArchiveCollections(workspaceRoot: root.path).execute(.init(action: "move", paths: [old], destination: "vault/archives/group", requestID: UUID().uuidString))
        // Reproduce a watcher committing to SQLite while collection UI was busy.
        _ = try indexer.reconcile()
        #expect(model.entries.contains { $0.path == old })
        let stats = try indexer.reconcile()
        #expect(stats.upserted + stats.removed == 0)
        model.archiveCollectionNeedsIndexReload = true
        await model.cliRefreshIndex()
        #expect(!model.archiveCollectionNeedsIndexReload)
        #expect(!model.entries.contains { $0.path == old })
        #expect(model.entries.contains { $0.path == "vault/archives/group/a/archive.md" })
        try await waitUntil { model.visibleEntries.count == 1 }
    }

    @Test func confirmedPathsReplaceVisibleCacheAndInvalidateOldLoads() async throws {
        let catalog = Catalog()
        let entry = Entry(path: "vault/archives/a/archive.md", type: .archive, title: "A", author: [], year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let pass = catalog.beginStandalonePass()
        catalog.publish([entry], pass: pass)
        catalog.recomputeVisible(searchText: "A", searchHits: [.init(entry: entry, score: 1, snippet: nil, source: "test")], pane: .type(.archive), entries: [entry], filters: [], match: .all, sorts: [])
        catalog.remapArchivePaths([.init(from: "vault/archives/a", to: "vault/archives/group/a")])
        #expect(catalog.visibleEntries.first?.path == "vault/archives/group/a/archive.md")
        #expect(catalog.entries.first?.path == catalog.visibleEntries.first?.path)
        #expect(!catalog.publish([entry], pass: pass))
    }

    private func fixture() async throws -> (URL, AppModel, VaultIndexer) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collection-refresh-\(UUID())")
        for (path, text) in ["vault/archives/a/archive.md": "---\ntype: archive\ntitle: A\n---\nA", "vault/archives/group/collection.md": "# Group"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let indexer = VaultIndexer(workspaceRoot: root.path)
        _ = try indexer.buildFull()
        let client = LocalVaultClient(workspaceRoot: root.path, index: IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path))
        let model = AppModel(client: client, workspaceRoot: root.path)
        model.cliIndexer = indexer
        await model.loadIndex()
        model.select(pane: .type(.archive))
        try await waitUntil { model.visibleEntries.count == 2 }
        return (root, model, indexer)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }
}
