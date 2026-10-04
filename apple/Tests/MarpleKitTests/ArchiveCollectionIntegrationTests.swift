import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor func archiveFieldFixture() async throws -> (URL, AppModel, VaultIndexer) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("collection-model-\(UUID())").resolvingSymlinksInPath()
    for (slug, fields) in [("a", "collection: Work\ntopics: [one, two]\n"), ("b", "collection: Work\ntopics: [two]\n"), ("c", "source: Independent\n")] {
        let dir = root.appendingPathComponent("vault/archives/\(slug)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\ntype: archive\ntitle: \(slug.uppercased()) Repair Manual\nkind: document\ncreated: 2026-10-04\n\(fields)---\n# \(slug)\nRepair instructions.\n".write(to: dir.appendingPathComponent("archive.md"), atomically: true, encoding: .utf8)
    }
    let indexer = VaultIndexer(workspaceRoot: root.path)
    _ = try indexer.buildFull()
    let db = IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path)
    let model = AppModel(client: LocalVaultClient(workspaceRoot: root.path, index: db), workspaceRoot: root.path)
    model.cliIndexer = indexer
    await model.loadIndex()
    model.select(pane: .type(.archive))
    try await waitForArchiveFields { model.archiveBrowseGroups.count == 2 }
    return (root, model, indexer)
}

@MainActor func waitForArchiveFields(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try #require(predicate())
}

@MainActor @Suite(.serialized)
struct ArchiveCollectionIntegrationTests {
    @Test func cliMembershipEditsKeepTabsHistoryAndDocumentLocations() async throws {
        let (root, model, indexer) = try await archiveFieldFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "vault/archives/a/archive.md"
        await model.openInNewTab(path)
        let tabID = try #require(model.activeTabID)
        model.setPinned([tabID], to: true)
        let history = try #require(model.tabs.first { $0.id == tabID }).history
        let command = ArchiveCollectionCommand(action: "assign", paths: [path], name: "Reading", requestID: UUID().uuidString)
        let response = await CLIHandlers.handle(.init(method: "collections", collection: command), model: model, indexer: indexer)
        #expect(response.ok)
        #expect(response.data?.collection?.moves.isEmpty == true)
        #expect(model.tabs.first { $0.id == tabID }?.pinnedLocation?.openPath == path)
        #expect(model.tabs.first { $0.id == tabID }?.history == history)
        #expect(model.entries.contains { $0.path == path })
        #expect(model.archiveFields[path]?["collection"] == ["Reading"])
        let replay = await CLIHandlers.handle(.init(method: "collections", collection: command), model: model, indexer: indexer)
        #expect(replay.ok && replay.data?.collection?.replayed == true)
        let status = await CLIHandlers.handle(.init(method: "collections", collection: .init(action: "status", requestID: command.requestID)), model: model, indexer: indexer)
        #expect(status.ok && status.data?.collection?.moves.isEmpty == true)
        #expect(model.openPath == path)
        #expect(model.openBody.contains("Repair instructions"))
    }
}
