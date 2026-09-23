import AppKit
import MarpleKit

/// Match Finder/FSNotes: right-click within the selection operates on the group;
/// right-click elsewhere first selects the clicked row. Header menus stay separate.
final class BrowseTableView: NSTableView {
    var onClickRow: ((Int) -> Void)? {
        didSet { target = self; action = #selector(clickRow) }
    }
    @objc private func clickRow() {
        guard clickedRow >= 0, NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty != false else { return }
        onClickRow?(clickedRow)
    }
    var onOpenRow: ((Int) -> Void)? {
        didSet { target = self; doubleAction = #selector(openClickedRow) }
    }
    @objc private func openClickedRow() { if clickedRow >= 0 { onOpenRow?(clickedRow) } }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, selectedRow >= 0 { onOpenRow?(selectedRow); return }
        super.keyDown(with: event)
    }
    var menuForBackground: (() -> NSMenu?)?
    var menuForRows: ((IndexSet) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0, clicked < numberOfRows,
              delegate?.tableView?(self, shouldSelectRow: clicked) != false else { return menuForBackground?() }
        window?.makeFirstResponder(self)
        if !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return menuForRows?(selectedRowIndexes)
    }
}

@MainActor enum BrowseEntryMenu {
    static func background(model: AppModel) -> NSMenu? {
        guard model.pane == .type(.archive), !model.isPinnedListContext else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionItem(title: String(localized: "新建空合集")) { model.formArchiveCollection([]) })
        return menu
    }

    static func make(entries: [Entry], model: AppModel) -> NSMenu? {
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        if entries.contains(where: \.isArchiveCollection) {
            guard entries.count == 1, let group = model.archiveCollection(at: entries[0].path) else { return nil }
            menu.addItem(ActionItem(title: model.expandedArchiveCollections.contains(group.path) ? String(localized: "收起合集") : String(localized: "展开合集")) { model.toggleArchiveCollection(entries[0].path) })
            menu.addItem(ActionItem(title: String(localized: "重命名合集")) { model.renameArchiveCollection(group) })
            menu.addItem(ActionItem(title: String(localized: "编辑合集说明")) {
                Task { try? await model.client.openInEditor(path: entries[0].path, app: "") }
            })
            return menu
        }
        appendArchiveActions(to: menu, entries: entries, model: model)
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

    static func appendArchiveActions(to menu: NSMenu, entries: [Entry], model: AppModel) {
        guard !entries.isEmpty, entries.allSatisfy({ $0.type == .archive && !$0.isArchiveCollection }) else { return }
        let paths = entries.map(\.path)
        let create = ActionItem(title: String(localized: "组成新合集")) { model.formArchiveCollection(paths) }
        create.isEnabled = !model.archiveCollectionBusy
        menu.addItem(create)
        if !model.archiveCollections.isEmpty {
            let move = NSMenuItem(title: String(localized: "移入合集"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for group in model.archiveCollections {
                let item = ActionItem(title: group.title) { model.moveArchives(paths, to: group.path) }
                item.isEnabled = !model.archiveCollectionBusy && !paths.allSatisfy { group.members.contains($0) }
                submenu.addItem(item)
            }
            move.submenu = submenu; menu.addItem(move)
        }
        if paths.contains(where: { path in model.archiveCollections.contains { $0.members.contains(path) } }) {
            let item = ActionItem(title: String(localized: "移出合集")) { model.moveArchives(paths, to: ArchiveCollections.base) }
            item.isEnabled = !model.archiveCollectionBusy; menu.addItem(item)
        }
        menu.addItem(.separator())
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
