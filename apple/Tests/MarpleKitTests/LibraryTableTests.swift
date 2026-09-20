import AppKit
import Testing
@testable import Marple
@testable import MarpleKit

@Suite(.serialized)
@MainActor
struct LibraryTableTests {
    @Test func sortingPreservesSelectionAndSpaceDragPayload() async throws {
        let model = try await makeModel()
        let coordinator = EntryTableView.Coordinator(model: model)
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? NSTableView)
        #expect(table.numberOfRows == 600)
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        try await waitUntil { model.openPath == "paper-4.md" }
        #expect(model.openPath == "paper-4.md")
        table.selectRowIndexes(IndexSet([4, 8]), byExtendingSelection: false)
        let selected = [4, 8].map { "entry:paper-\($0).md" }
        table.sortDescriptors = [NSSortDescriptor(key: "title", ascending: false)]
        let expectedFirst = sortEntries(model.entries, by: [SortClause(field: .title, dir: .desc)]).first?.path
        try await waitUntil {
            (coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)?
                .string(forType: SidebarDragPasteboard.tabItem) == expectedFirst.map { "entry:\($0)" }
        }
        #expect(model.activeSortClauses == [SortClause(field: .title, dir: .desc)])
        let payloads = table.selectedRowIndexes.compactMap {
            (coordinator.tableView(table, pasteboardWriterForRow: $0) as? NSPasteboardItem)?
                .string(forType: SidebarDragPasteboard.tabItem)
        }
        #expect(Set(payloads) == Set(selected))
        #expect(model.openPath == "paper-4.md")
        await model.open("paper-30.md")
        try await waitUntil {
            (coordinator.tableView(table, pasteboardWriterForRow: table.selectedRow) as? NSPasteboardItem)?
                .string(forType: SidebarDragPasteboard.tabItem) == "entry:paper-30.md"
        }
        #expect(table.selectedRowIndexes.count == 1)
        let active = coordinator.tableView(table, pasteboardWriterForRow: table.selectedRow) as? NSPasteboardItem
        #expect(active?.string(forType: SidebarDragPasteboard.tabItem) == "entry:paper-30.md")
        model.togglePin(try #require(model.activeTabID))
        try await waitUntil { table.numberOfRows == 1 }
        #expect(table.tableColumns.allSatisfy { $0.sortDescriptorPrototype == nil })
    }

    @Test func browseModesPreserveFourColumnsAndRightSide() async throws {
        let model = try await makeModel()
        await model.open("paper-4.md")
        let shell = MarpleSplitViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = shell
        let toolbar = MarpleToolbarController()
        toolbar.model = model
        toolbar.shell = shell
        toolbar.splitView = shell.splitView
        window.toolbar = toolbar.makeToolbar()
        window.setContentSize(NSSize(width: 1440, height: 760))
        shell.view.wantsLayer = true
        shell.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.orderFront(nil)
        defer { window.close() }
        try await settle(shell)
        #expect(shell.splitViewItems.count == 4)
        let reader = shell.splitViewItems[2].viewController
        let properties = shell.splitViewItems[3].viewController
        #expect(!(properties is NSSplitViewController))
        let originalToolbar = window.toolbar
        let modeControl = try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "browseMode"
        } as? NSToolbarItemGroup)
        #expect(modeControl.selectedIndex == 0)
        #expect(modeControl.selectionMode == .selectOne)
        #expect(modeControl.controlRepresentation == .expanded)
        let action = try #require(modeControl.action)
        for (index, mode) in [BrowseMode.grid, .list, .table].enumerated() {
            modeControl.selectedIndex = index
            #expect(NSApp.sendAction(action, to: modeControl.target, from: modeControl))
            try await waitUntil { model.browseMode == mode }
            try await settle(shell)
            #expect(modeControl.selectedIndex == index)
            #expect(shell.splitViewItems.count == 4)
            #expect(shell.splitViewItems[2].viewController === reader)
            #expect(shell.splitViewItems[3].viewController === properties)
            #expect(!shell.splitViewItems[3].isCollapsed)
            #expect(window.toolbar === originalToolbar)
            #expect(model.openPath == "paper-4.md")
            if mode == .grid {
                try snapshot(try #require(window.contentView?.superview), name: "four-column-grid")
            }
        }
        let table = try #require(descendants(of: NSTableView.self, in: shell.view).first {
            $0.headerView != nil && $0.numberOfColumns == 5
        })
        #expect(table.numberOfRows == 600)
        #expect(table.selectedRow == 4)
        let ids = window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
        #expect(ids.contains("readerSeparator"))
        #expect(ids.contains("inspectorSeparator"))
        try snapshot(try #require(window.contentView?.superview), name: "four-column-table")
        model.browseMode = .list
        try await waitUntil { modeControl.selectedIndex == 1 }
        model.togglePin(try #require(model.activeTabID))
        model.browseMode = .grid
        try await waitUntil { !modeControl.subitems[0].isEnabled }
        #expect(modeControl.selectedIndex == 1)
        model.select(pane: .trash)
        try await waitUntil { !modeControl.isEnabled }
        model.select(pane: .type(.paper))
        try await waitUntil { modeControl.isEnabled && modeControl.subitems[0].isEnabled }
        #expect(modeControl.selectedIndex == 0)
    }

    private func makeModel() async throws -> AppModel {
        let titles = ["演化论与目的论：关于自然解释的研究", "The Structure of Scientific Revolutions", "图像、记忆与知识的秩序", "On the Origin of Species", "如何阅读一篇学术论文"]
        let entries = (0..<600).map { i in
            Entry(path: "paper-\(i).md", type: .paper, title: "\(titles[i % titles.count]) · \(i)",
                  author: [i % 2 == 0 ? "张明" : "Thomas S. Kuhn"], year: "\(2000 + i % 25)",
                  ratingScore: 4, themes: ["科学史"], preview: "研究问题、论证与资料。", hasPDF: false)
        }
        let body = "# 演化论与目的论\n\n## 研究问题\n\n理解历史中的自然解释，需要区分过程与目的。这里展示文献的正文预览，选中不同资料即可继续阅读。\n\n## 论证与材料\n\n" + String(repeating: "这一节讨论概念的变化及其证据。\n\n", count: 30)
        let model = AppModel(client: StubVaultClient(entries: entries,
            texts: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, body) })))
        await model.loadIndex()
        model.select(pane: .type(.paper))
        try await waitUntil { model.visibleEntries.count == 600 }
        return model
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }

    private func settle(_ shell: MarpleSplitViewController) async throws {
        try await Task.sleep(for: .milliseconds(180))
        shell.view.layoutSubtreeIfNeeded()
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(of: type, in: child) }
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["MARPLE_LIBRARY_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url.appendingPathComponent("\(name).png"))
    }
}
