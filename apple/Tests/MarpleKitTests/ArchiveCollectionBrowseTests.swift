import AppKit
import SwiftUI
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor @Suite(.serialized)
struct ArchiveCollectionBrowseTests {
    @Test func mixedRowsMenusAndDropToCreateThenMove() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-collection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for slug in ["a", "b", "c"] {
            let dir = root.appendingPathComponent("vault/archives/\(slug)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\ntype: archive\ntitle: \(slug.uppercased()) Repair Manual\n---\n\(slug) Repair instructions and source notes.\n".write(to: dir.appendingPathComponent("archive.md"), atomically: true, encoding: .utf8)
        }
        let store = ArchiveCollections(workspaceRoot: root.path)
        _ = try store.execute(.init(action: "create", name: "维修资料", requestID: UUID().uuidString))
        let indexer = VaultIndexer(workspaceRoot: root.path)
        _ = try indexer.buildFull()
        let db = IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path)
        let model = AppModel(client: LocalVaultClient(workspaceRoot: root.path, index: db), workspaceRoot: root.path)
        model.cliIndexer = indexer
        await model.loadIndex()
        model.select(pane: .type(.archive))
        model.setSort([.init(field: .title, dir: .asc)])
        try await waitUntil { model.visibleEntries.count == 4 }
        #expect(model.visibleEntries.filter(\.isArchiveCollection).count == 1)
        let a = try #require(model.entries.first { $0.path.contains("/a/") })
        let b = try #require(model.entries.first { $0.path.contains("/b/") })
        let c = try #require(model.entries.first { $0.path.contains("/c/") })
        let menu = try #require(BrowseEntryMenu.make(entries: [a, b], model: model))
        #expect(menu.items.contains { $0.title == String(localized: "组成新合集") })
        #expect(menu.items.first { $0.title == String(localized: "移入合集") }?.submenu?.items.count == 1)
        let board = NSPasteboard(name: .init("collection-test-\(UUID())"))
        defer { board.releaseGlobally() }
        func drag(_ entries: [Entry]) {
            board.clearContents()
            board.writeObjects(entries.map { entry in
                let item = NSPasteboardItem(); item.setString("entry:" + entry.path, forType: SidebarDragPasteboard.tabItem); return item
            })
        }
        drag([a, b])
        #expect(ArchiveEntryDrop.paths(board, onto: b, model: model) == nil) // No self merge.
        #expect(ArchiveEntryDrop.accept(board, onto: c, model: model))
        try await waitUntil { model.archiveCollections.contains { $0.members.count == 3 } && !model.archiveCollectionBusy }
        #expect(model.visibleEntries.count == 2) // Two folders; the three members are collapsed.
        let group = try #require(model.archiveCollections.first { $0.members.count == 3 })
        let folder = try #require(model.visibleEntries.first { $0.path == group.path + "/collection.md" })
        let folderMenu = try #require(BrowseEntryMenu.make(entries: [folder], model: model))
        #expect(!folderMenu.items.contains { $0.title == String(localized: "移到回收站") })
        #expect(folderMenu.items.contains { $0.title == String(localized: "重命名合集") })
        await model.activateVisibleEntry(folder.path)
        #expect(model.archiveCollectionPath == nil) // Single click only selects.
        await model.open(folder.path)
        #expect(model.archiveCollectionPath == group.path)
        #expect(model.visibleEntries.count == 3)
        let moved = model.visibleEntries
        let insideMenu = try #require(BrowseEntryMenu.make(entries: moved, model: model))
        #expect(insideMenu.items.contains { $0.title == String(localized: "移出合集") })
        model.archiveCollectionPath = nil
        let destination = try #require(model.visibleEntries.first { $0.title == "维修资料" })
        drag(moved)
        #expect(ArchiveEntryDrop.accept(board, onto: destination, model: model))
        try await waitUntil { model.archiveCollections.first { $0.title == "维修资料" }?.members.count == 3 && !model.archiveCollectionBusy }
        #expect(try store.inventory().ungrouped.isEmpty)
        // Keep one standalone entry next to the collection for the visual fixture.
        let path = try #require(model.archiveCollections.first { $0.title == "维修资料" }?.members.last)
        _ = try await model.performArchiveCollection(.init(action: "move", paths: [path], destination: ArchiveCollections.base))
        if let output = ProcessInfo.processInfo.environment["MARPLE_INLINE_COLLECTION_SNAPSHOT"] {
            _ = NSApplication.shared
            let host = NSHostingView(rootView: HStack(spacing: 0) {
                EntryListTable(model: model).frame(width: 330)
                Divider()
                CollectionGridVariant(model: model, columnWidth: 160).frame(width: 380)
                Divider()
                EntryTableView(model: model).frame(width: 500)
            }.background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1212, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.setFrameOrigin(.init(x: -10000, y: -10000)); window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
        let before = model.archiveCollections.count
        let background = try #require(BrowseEntryMenu.background(model: model))
        let createEmpty = try #require(background.items.first)
        #expect(createEmpty.title == String(localized: "新建空合集"))
        NSApp.sendAction(try #require(createEmpty.action), to: createEmpty.target, from: createEmpty)
        try await waitUntil { model.archiveCollections.count == before + 1 && !model.archiveCollectionBusy }
        #expect(model.archiveCollections.filter { $0.members.isEmpty }.count == 2)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }
}
