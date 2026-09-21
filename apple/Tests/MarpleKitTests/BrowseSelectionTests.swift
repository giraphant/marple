import AppKit
import SwiftUI
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor @Suite(.serialized) struct BrowseSelectionTests {
    @Test func listNativeMultiSelectionSurvivesRefreshAndSorting() async throws {
        let model = try await makeModel()
        let host = NSHostingView(rootView: EntryListTable(model: model))
        let window = makeWindow(content: host)
        defer { window.close() }
        try await waitUntil { self.findTable(in: host)?.numberOfRows == 15 }
        let table = try #require(findTable(in: host))
        #expect(table.allowsMultipleSelection)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await waitUntil { model.openPath == model.visibleEntries[0].path }
        for _ in 0..<3 { try extendSelectionDown(in: table) }
        #expect(table.selectedRowIndexes == IndexSet([0, 2, 4, 6]))
        table.deselectRow(2)
        #expect(table.selectedRowIndexes == IndexSet([0, 4, 6]))
        table.selectRowIndexes(IndexSet(integer: 8), byExtendingSelection: true)
        #expect(table.selectedRowIndexes == IndexSet([0, 4, 6, 8]))
        let selectedPaths = Set(table.selectedRowIndexes.map { model.visibleEntries[$0 / 2].path })
        await model.loadIndex()
        try await Task.sleep(for: .milliseconds(100))
        #expect(table.selectedRowIndexes == IndexSet([0, 4, 6, 8]))
        model.setSort([SortClause(field: .title, dir: .desc)])
        try await waitUntil { model.visibleEntries.first?.path == "paper-7.md" }
        try await Task.sleep(for: .milliseconds(100))
        #expect(Set(table.selectedRowIndexes.map { model.visibleEntries[$0 / 2].path }) == selectedPaths)
        // Single selection restores normal reading; Command-style deselection stays empty.
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await waitUntil { model.openPath == "paper-7.md" }
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        table.deselectRow(0)
        #expect(table.selectedRowIndexes.isEmpty)
        await model.loadIndex()
        try await Task.sleep(for: .milliseconds(100))
        #expect(table.selectedRowIndexes.isEmpty)
    }

    @Test func tableAndListMenusTargetTheClickedSelection() async throws {
        let model = try await makeModel()
        let coordinator = EntryTableView.Coordinator(model: model)
        let scroll = coordinator.makeScrollView()
        let window = makeWindow(content: scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? NSTableView)
        table.selectRowIndexes(IndexSet([1, 3]), byExtendingSelection: false)
        let groupMenu = try #require(try menu(row: 3, in: table))
        #expect(table.selectedRowIndexes == IndexSet([1, 3]))
        #expect(groupMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            String(localized: "在新页面页打开"), String(localized: "移到回收站")])
        #expect(table.headerView?.menu != nil)
        let open = try #require(groupMenu.items.first)
        NSApp.sendAction(try #require(open.action), to: open.target, from: open)
        try await waitUntil { model.openPath == "paper-3.md" }
        #expect(model.workspace?.tabs.contains { $0.location.openPath == "paper-1.md" } == true)
        #expect(model.workspace?.tabs.contains { $0.location.openPath == "paper-3.md" } == true)
        let single = try #require(try menu(row: 5, in: table))
        #expect(table.selectedRowIndexes == IndexSet(integer: 5))
        #expect(single.items.contains { $0.title == String(localized: "新建批注") })
        let blank = try mouse(.rightMouseDown, point: NSPoint(x: 10, y: table.bounds.maxY + 50), in: table, flags: [])
        #expect(table.menu(for: blank) == nil)

        let host = NSHostingView(rootView: EntryListTable(model: model))
        window.contentView = host
        try await waitUntil { self.findTable(in: host)?.numberOfRows == 15 }
        let list = try #require(findTable(in: host))
        list.selectRowIndexes(IndexSet([0, 4]), byExtendingSelection: false)
        #expect(try menu(row: 4, in: list)?.items.filter { !$0.isSeparatorItem }.count == 2)
        #expect(list.selectedRowIndexes == IndexSet([0, 4]))
        #expect(try menu(row: 2, in: list)?.items.filter { !$0.isSeparatorItem }.count == 3)
        #expect(list.selectedRowIndexes == IndexSet(integer: 2))
        #expect(try menu(row: 1, in: list) == nil) // Spacer.
    }

    private func extendSelectionDown(in table: NSTableView) throws {
        table.window?.makeFirstResponder(table)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift, .numericPad, .function], timestamp: 0,
            windowNumber: table.window!.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        table.keyDown(with: event)
    }

    private func menu(row: Int, in table: NSTableView) throws -> NSMenu? {
        let rect = table.rect(ofRow: row)
        return table.menu(for: try mouse(.rightMouseDown, point: NSPoint(x: 30, y: rect.midY), in: table, flags: []))
    }

    private func mouse(_ type: NSEvent.EventType, point: NSPoint, in table: NSTableView,
                       flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: table.convert(point, to: nil), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: table.window!.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func makeWindow(content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeModel() async throws -> AppModel {
        _ = NSApplication.shared
        let entries = (0..<8).map { i in
            Entry(path: "paper-\(i).md", type: .paper, title: "Paper \(i)", author: [], year: nil,
                  ratingScore: 0, themes: [], preview: "Summary", hasPDF: false)
        }
        let model = AppModel(client: StubVaultClient(entries: entries,
            texts: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, "# Body") })))
        await model.loadIndex()
        model.select(pane: .type(.paper))
        model.setSort([SortClause(field: .title, dir: .asc)])
        try await waitUntil { model.visibleEntries.count == 8 }
        return model
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }
}
