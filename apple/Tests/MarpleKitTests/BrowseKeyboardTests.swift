import AppKit
import SwiftUI
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor @Suite(.serialized) struct BrowseKeyboardTests {
    @Test func arrowsKeepWorkingAcrossBrowseModes() async throws {
        _ = NSApplication.shared
        let entries = (0..<20).map { i in
            Entry(path: "paper-\(i).md", type: .paper, title: String(format: "Paper %02d", i),
                  author: [], year: nil, ratingScore: 0, themes: [], preview: "Summary", hasPDF: false)
        }
        let model = AppModel(client: StubVaultClient(entries: entries,
            texts: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, "# \($0.title!)\nBody") })))
        await model.loadIndex()
        model.select(pane: .type(.paper))
        try await waitUntil { model.visibleEntries.count == 20 }
        await model.open(model.visibleEntries[0].path)
        model.browseMode = .list
        let shell = MarpleSplitViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = shell
        let toolbar = MarpleToolbarController()
        toolbar.model = model; toolbar.shell = shell; toolbar.splitView = shell.splitView
        window.toolbar = toolbar.makeToolbar()
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let browse = shell.splitViewItems[1].viewController.view
        try await waitUntil { self.find(NSTableView.self, in: browse)?.numberOfRows == 39 }
        let table = try #require(find(NSTableView.self, in: browse))
        window.makeFirstResponder(table) // One initial click, then keyboard-only browsing.
        for index in 1...3 {
            try down(in: window)
            try await waitUntil { model.openPath == model.visibleEntries[index].path }
            #expect(window.firstResponder === table)
        }
        for (identifier, type) in [("browseGrid", BrowseMode.grid), ("browseTable", .table), ("browseList", .list)] {
            let button = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == identifier }?.view as? NSButton)
            button.performClick(nil)
            try await waitUntil { model.browseMode == type }
            try await Task.sleep(for: .milliseconds(150))
            shell.view.layoutSubtreeIfNeeded()
            let target: NSView? = type == .grid ? find(NSCollectionView.self, in: browse) : find(NSTableView.self, in: browse)
            #expect(window.firstResponder === target)
            if let grid = target as? NSCollectionView {
                let before = grid.selectionIndexPaths
                try down(in: window)
                #expect(grid.selectionIndexPaths != before)
            } else if let table = target as? NSTableView {
                let before = table.selectedRow
                try down(in: window)
                #expect(table.selectedRow > before)
            }
        }
        // A refresh or presentation change must not take arrow keys from text
        // editing or a reader the user deliberately focused.
        let reader = try #require(find(NSTextView.self, in: shell.splitViewItems[2].viewController.view))
        window.makeFirstResponder(reader)
        model.browseMode = .grid
        try await waitUntil { self.find(NSCollectionView.self, in: browse) != nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder === reader)
        reader.isEditable = true
        model.browseMode = .table
        try await waitUntil { self.find(NSTableView.self, in: browse) != nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder === reader)
    }

    private func down(in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        window.sendEvent(event)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }
}
