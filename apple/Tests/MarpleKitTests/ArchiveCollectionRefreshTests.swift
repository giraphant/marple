import AppKit
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor @Suite(.serialized)
struct ArchiveCollectionRefreshTests {
    @Test func metadataWriteImmediatelyRefreshesNativeTableAndRenameKeepsExpansion() async throws {
        _ = NSApplication.shared
        let (root, model, _) = try await archiveFieldFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = try #require(model.archiveBrowseGroups.first { $0.value == "Work" })
        model.expandedArchiveCollections.insert(group.id)
        let coordinator = EntryTableView.Coordinator(model: model)
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? BrowseTableView)
        #expect(table.numberOfRows == 4)
        _ = try await model.performArchiveCollection(.init(action: "assign", paths: ["vault/archives/c"], name: "Work"))
        try await waitForArchiveFields { table.numberOfRows == 4 && model.archiveBrowseGroups.count == 1 }
        #expect((0..<4).compactMap { coordinator.dropEntry(at: $0) }.filter { !$0.isArchiveCollection }.count == 3)
        _ = try await model.performArchiveCollection(.init(action: "rename", paths: ["Work"], name: "Renamed"))
        let renamed = try #require(model.archiveBrowseGroups.first { $0.value == "Renamed" })
        #expect(model.expandedArchiveCollections.contains(renamed.id))
        #expect(model.visibleEntries.count == 4)
        model.archiveGrouping = nil
        try await waitForArchiveFields { table.numberOfRows == 3 }
        #expect(model.visibleEntries.allSatisfy { !$0.isArchiveCollection })
    }

    @Test func externalFieldEditRefreshesWithoutMovingOrReindexingPaths() async throws {
        let (root, model, indexer) = try await archiveFieldFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = model.entries.map(\.path)
        _ = try ArchiveCollections(workspaceRoot: root.path).execute(.init(action: "assign", paths: ["vault/archives/c"], name: "External", requestID: UUID().uuidString))
        _ = try indexer.reconcile()
        model.archiveCollectionNeedsIndexReload = true
        await model.cliRefreshIndex()
        #expect(!model.archiveCollectionNeedsIndexReload)
        #expect(model.entries.map(\.path) == paths)
        #expect(model.archiveCollections.contains { $0.title == "External" })
    }
}
