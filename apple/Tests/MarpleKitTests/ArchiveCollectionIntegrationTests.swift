import Foundation
import Testing
import SwiftUI
import AppKit
@testable import Marple
@testable import MarpleKit

@Suite @MainActor
struct ArchiveCollectionIntegrationTests {
    @Test func cliMoveRefreshesIndexAndPreservesPinnedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collection-ui-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "vault/archives/example/archive.md"
        let group = "vault/archives/维修资料"
        for (path, body) in [
            original: "---\ntype: archive\ntitle: 电池维修手册\nkind: document\ncreated: 2026-09-23\n---\n# 电池维修手册\n档案正文。\n",
            group + "/collection.md": "# 维修资料\n我的笔记。\n",
            "vault/notes/n.md": "---\ntype: note\ntitle: Notes\n---\nNote\n"
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        let indexer = VaultIndexer(workspaceRoot: root.path)
        _ = try indexer.buildFull()
        let db = IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path)
        let model = AppModel(client: LocalVaultClient(workspaceRoot: root.path, index: db), workspaceRoot: root.path)
        model.cliIndexer = indexer
        await model.loadIndex()
        await model.openInNewTab(original)
        let tabID = try #require(model.activeTabID)
        model.setPinned([tabID], to: true)
        await model.open("vault/notes/n.md")
        let command = ArchiveCollectionCommand(action: "move", paths: [original], destination: group, requestID: UUID().uuidString)
        let response = await CLIHandlers.handle(.init(method: "collections", collection: command), model: model, indexer: indexer)
        #expect(response.ok)
        #expect(response.data?.collection?.replayed == false)
        let moved = group + "/example/archive.md"
        let tab = try #require(model.tabs.first { $0.id == tabID })
        #expect(tab.pinnedLocation?.openPath == moved)
        #expect(tab.history.entries.contains { $0.openPath == moved })
        #expect(!tab.history.entries.contains { $0.openPath == original })
        #expect(model.entries.contains { $0.path == moved })
        #expect(!model.entries.contains { $0.path == original })
        let replay = await CLIHandlers.handle(.init(method: "collections", collection: command), model: model, indexer: indexer)
        #expect(replay.ok && replay.data?.collection?.replayed == true)
        #expect(model.tabs.first { $0.id == tabID }?.history == tab.history)
        let status = await CLIHandlers.handle(.init(method: "collections", collection: .init(action: "status", requestID: command.requestID)), model: model, indexer: indexer)
        #expect(status.ok && status.data?.collection?.moves.first?.to == group + "/example")
        model.select(pane: .type(.archive))
        model.expandedArchiveCollections.insert(group)
        await model.openInNewTab(moved)
        #expect(model.openEntry?.path == moved)
        #expect(model.openBody.contains("档案正文"))

        if let output = ProcessInfo.processInfo.environment["MARPLE_COLLECTION_SNAPSHOT"] {
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                ArchiveCollectionsView(model: model)
                Divider()
                Text("电池维修手册").font(.title2).frame(maxWidth: .infinity, alignment: .leading).padding()
                Spacer()
            }.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
}
