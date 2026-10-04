import AppKit
import SwiftUI
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor @Suite(.serialized)
struct ArchiveCollectionBrowseTests {
    @Test func groupingIsDisplayOnlyAndTopicsCanAppearTwice() async throws {
        _ = NSApplication.shared
        let (root, model, _) = try await archiveFieldFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = "vault/archives/a/archive.md"
        let before = try Data(contentsOf: root.appendingPathComponent(a))
        #expect(model.archiveGroupingFields.contains("collection"))
        #expect(model.archiveGroupingFields.contains("source"))
        model.archiveGrouping = "topics"
        #expect(model.archiveBrowseGroups.count == 3)
        model.expandedArchiveCollections = Set(model.archiveBrowseGroups.map(\.id))
        #expect(model.visibleEntries.filter { $0.path == a }.count == 2)
        #expect(model.visibleEntryCount == 3)
        model.archiveGrouping = nil
        #expect(model.visibleEntries.count == 3)
        #expect(model.visibleEntries.allSatisfy { !$0.isArchiveCollection })
        #expect(try Data(contentsOf: root.appendingPathComponent(a)) == before)
        model.archiveGrouping = "source"
        #expect(model.archiveBrowseGroups.first?.value == "Independent")
        #expect(model.archiveBrowseGroups.last?.value == nil)
        model.setFilters([.init(field: .source, op: .is_, value: "Independent")], match: .all)
        try await waitForArchiveFields { model.archiveBrowseGroups.count == 1 }
        #expect(model.archiveBrowseGroups[0].members == ["vault/archives/c/archive.md"])

        // Global search can also return other types; Archive grouping must keep
        // those visible without pretending they are unclassified Archives.
        let archive = try #require(model.entries.first { $0.path == a })
        let paper = Entry(path: "paper.md", type: .paper, title: "Paper", author: [], year: nil,
                          ratingScore: 0, themes: [], preview: "", hasPDF: false)
        model.catalog.recomputeVisible(searchText: "search", searchHits: [archive, paper].map {
            SearchHit(entry: $0, score: 1, snippet: nil, source: "test")
        }, pane: .type(.archive), entries: [], filters: [], match: .all, sorts: [])
        #expect(model.archiveBrowseGroups.flatMap(\.members) == [a])
        #expect(model.visibleEntries.contains(paper))
    }

    @Test func groupMenusAndDragEditOnlyCollection() async throws {
        _ = NSApplication.shared
        let (root, model, _) = try await archiveFieldFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try #require(model.entries.first { $0.path.contains("/c/") })
        let group = try #require(model.visibleEntries.first { $0.title == "Work" })
        let menu = try #require(BrowseEntryMenu.make(entries: [group], model: model))
        #expect(menu.items.contains { $0.title == String(localized: "重命名合集") })
        #expect(menu.items.contains { $0.title == String(localized: "移出合集") })
        #expect(!menu.items.contains { $0.title == String(localized: "编辑合集说明") })
        let board = NSPasteboard(name: .init("field-drop-\(UUID())"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("entry:" + c.path, forType: SidebarDragPasteboard.tabItem)
        board.writeObjects([item])
        let accepted = ArchiveEntryDrop.accept(board, onto: group, model: model)
        #expect(accepted)
        try await waitForArchiveFields { model.archiveCollections.first?.members.count == 3 && !model.archiveCollectionBusy }
        #expect(model.entries.contains { $0.path == c.path })
        model.archiveGrouping = "topics"
        let topic = try #require(model.visibleEntries.first)
        #expect(ArchiveEntryDrop.paths(board, onto: topic, model: model) == nil)
        let topicMenu = try #require(BrowseEntryMenu.make(entries: [topic], model: model))
        #expect(!topicMenu.items.contains { $0.title == String(localized: "重命名合集") })
        model.formArchiveCollection([c.path])
        #expect(model.archiveCollectionAssignPaths == [c.path])
        #expect(model.archiveCollections.count == 1)
    }

    @Test func collectionNamingPromptWorksOutsideArchiveBrowse() async throws {
        _ = NSApplication.shared
        let (root, model, _) = try await archiveFieldFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.select(pane: .type(.paper))
        let host = NSHostingView(rootView: BrowseColumn(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(.init(x: -10000, y: -10000))
        window.orderFront(nil)
        defer {
            model.archiveCollectionAssignPaths = nil
            for sheet in window.sheets { window.endSheet(sheet) }
            window.close()
        }
        model.formArchiveCollection(["vault/archives/a/archive.md"])
        try await waitForArchiveFields { !window.sheets.isEmpty }
        #expect(model.archiveCollections.map(\.title) == ["Work"])
    }

    @Test func renderGroupedViews() async throws {
        guard let output = ProcessInfo.processInfo.environment["MARPLE_INLINE_COLLECTION_SNAPSHOT"] else { return }
        _ = NSApplication.shared
        let (root, model, _) = try await archiveFieldFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.expandedArchiveCollections = Set(model.archiveBrowseGroups.map(\.id))
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            EntryListView(model: model).frame(width: 330)
            Divider()
            EntryGridView(model: model).frame(width: 380)
            Divider()
            EntryTableView(model: model).frame(width: 500)
        }.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1212, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.setFrameOrigin(.init(x: -10000, y: -10000)); window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}
