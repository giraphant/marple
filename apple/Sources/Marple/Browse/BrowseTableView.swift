import AppKit
import MarpleKit

/// Match Finder/FSNotes: right-click within the selection operates on the group;
/// right-click elsewhere first selects the clicked row. Header menus stay separate.
final class BrowseTableView: NSTableView {
    var menuForRows: ((IndexSet) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0, clicked < numberOfRows,
              delegate?.tableView?(self, shouldSelectRow: clicked) != false else { return nil }
        window?.makeFirstResponder(self)
        if !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return menuForRows?(selectedRowIndexes)
    }
}

@MainActor enum BrowseEntryMenu {
    static func make(entries: [Entry], model: AppModel) -> NSMenu? {
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionItem(title: String(localized: "在新页面页打开")) { [weak model] in
            Task { for entry in entries { await model?.openInNewTab(entry.path) } }
        })
        if let entry = entries.first, entries.count == 1 {
            menu.addItem(ActionItem(title: String(localized: "新建批注")) { [weak model] in
                Task { await model?.newAnnotation(for: entry) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem(title: String(localized: "移到回收站")) { [weak model] in
            Task { for entry in entries { await model?.moveToTrash(entry.path) } }
        })
        return menu
    }

    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void
        init(title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func run() { handler() }
    }
}
