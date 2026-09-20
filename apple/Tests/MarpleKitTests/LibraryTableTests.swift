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

    @Test func threeColumnsStayStableAndReuseReaderAndProperties() async throws {
        let prior = UserDefaults.standard.object(forKey: SettingsKeys.threeColumnLayout)
        defer { UserDefaults.standard.set(prior, forKey: SettingsKeys.threeColumnLayout) }
        let model = try await makeModel()
        model.threeColumnLayout = true
        model.browseMode = .table
        await model.open("paper-4.md")
        let shell = MarpleSplitViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = shell
        let toolbar = MarpleToolbarController()
        toolbar.model = model
        toolbar.shell = shell
        toolbar.splitView = shell.splitView
        window.toolbar = toolbar.makeToolbar()
        shell.onLayoutChange = { [weak window, weak toolbar] in
            window?.toolbar = toolbar?.makeToolbar()
        }
        window.setContentSize(NSSize(width: 1280, height: 760))
        shell.view.wantsLayer = true
        shell.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.orderFront(nil)
        defer { window.close() }
        try await settle(shell)
        #expect(shell.splitViewItems.count == 3)
        let right = try #require(shell.splitViewItems.last?.viewController as? NSSplitViewController)
        #expect(!right.splitView.isVertical)
        let reader = right.splitViewItems[0].viewController
        let properties = right.splitViewItems[1].viewController
        let table = try #require(descendants(of: NSTableView.self, in: shell.view).first { $0.headerView != nil && $0.numberOfColumns == 5 })
        #expect(table.selectedRow == 4)
        table.autosaveTableColumns = false
        for width in [960, 1280, 1440] {
            window.setContentSize(NSSize(width: width, height: 760))
            try await settle(shell)
            #expect(shell.splitViewItems.count == 3)
            #expect(shell.splitViewItems[1].viewController.view.frame.width >= 320)
            #expect(right.view.frame.width >= 340)
            #expect(reader.view.frame.height >= 260)
            #expect(reader.view.frame.height < 400)
            #expect(properties.view.frame.height >= 180)
            for column in table.tableColumns {
                column.isHidden = false
                column.width = ["title": 300.0, "author": 132, "year": 60, "rating": 64, "added": 110][column.identifier.rawValue]!
            }
            table.sizeToFit()
            try await settle(shell)
            try snapshot(shell.view, name: "\(width)-five-columns")
            print("[ablation] five width=\(width) title=\(table.tableColumns[0].width) table=\(table.frame.width) clip=\(table.enclosingScrollView?.contentSize.width ?? 0)")
            for column in table.tableColumns.suffix(2) { column.isHidden = true }
            table.sizeToFit()
            try await settle(shell)
            #expect(table.frame.width <= (table.enclosingScrollView?.contentSize.width ?? 0) + 1)
            try snapshot(shell.view, name: "\(width)-three-columns")
            print("[ablation] width=\(width) panes=\(shell.splitView.arrangedSubviews.map { $0.frame.width }) title=\(table.tableColumns[0].width) preview=\(reader.view.frame.height) properties=\(properties.view.frame.height)")
        }
        window.setContentSize(NSSize(width: 960, height: 560))
        try await settle(shell)
        #expect(reader.view.frame.height >= 260)
        #expect(properties.view.frame.height >= 180)
        try snapshot(shell.view, name: "960-short-window")
        window.setContentSize(NSSize(width: 1440, height: 760))
        try await settle(shell)
        right.splitView.setPosition(360, ofDividerAt: 0)
        try await settle(shell)
        #expect(abs(reader.view.frame.height - 360) < 2)
        let preview = right.splitViewItems[0]
        preview.canCollapse = true
        preview.isCollapsed = true
        try await settle(shell)
        try snapshot(shell.view, name: "1440-no-preview")
        preview.isCollapsed = false
        model.select(pane: .type(.paper))
        try await settle(shell)
        #expect(shell.splitViewItems.count == 3)
        #expect(!shell.splitViewItems[2].isCollapsed)
        await model.open("paper-8.md")
        model.threeColumnLayout = false
        try await settle(shell)
        #expect(shell.splitViewItems.count == 4)
        #expect(shell.splitViewItems[2].viewController === reader)
        #expect(shell.splitViewItems[3].viewController === properties)
        model.threeColumnLayout = true
        try await settle(shell)
        let restored = try #require(shell.splitViewItems.last?.viewController as? NSSplitViewController)
        #expect(restored.splitViewItems[0].viewController === reader)
        #expect(restored.splitViewItems[1].viewController === properties)
        #expect(model.openPath == "paper-8.md")
        let ids = window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
        #expect(ids.contains("readerSeparator"))
        #expect(!ids.contains("inspectorSeparator"))
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
        guard let dir = ProcessInfo.processInfo.environment["MARPLE_ABLATION_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url.appendingPathComponent("\(name).png"))
    }
}
