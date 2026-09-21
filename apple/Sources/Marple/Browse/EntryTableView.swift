import AppKit
import SwiftUI
import MarpleKit

/// Compact, reusable native cells. Sorting and Space drops use the same model
/// and pasteboard protocol as the existing browse views.
struct EntryTableView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ view: NSScrollView, context: Context) {}

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        private var entries: [Entry] = []
        private var updating = false
        private var lastOpenPath: String?
        weak var table: NSTableView?

        init(model: AppModel) { self.model = model }

        func makeScrollView() -> NSScrollView {
            let table = NSTableView()
            table.style = .fullWidth
            table.rowHeight = 28
            table.intercellSpacing = .zero
            table.autoresizingMask = [.width]
            table.usesAlternatingRowBackgroundColors = true
            table.allowsMultipleSelection = true
            table.allowsColumnReordering = true
            table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            let menu = NSMenu()
            menu.delegate = self
            for (field, width) in [(SortField.title, 300.0), (.author, 132), (.year, 60), (.rating, 64), (.added, 110)] {
                let column = NSTableColumn(identifier: .init(field.rawValue))
                column.title = AppPresentation.sortFieldLabel(field)
                column.width = width
                column.minWidth = field == .title ? 180 : 54
                column.resizingMask = field == .title ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
                column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: field.defaultDir == .asc)
                column.isHidden = field == .rating || field == .added
                table.addTableColumn(column)
                if field != .title {
                    let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = column
                    item.state = column.isHidden ? .off : .on
                    menu.addItem(item)
                }
            }
            table.headerView?.menu = menu
            table.autosaveName = "MarpleLibraryTable"
            table.autosaveTableColumns = true
            table.delegate = self
            table.dataSource = self
            table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
            table.setAccessibilityLabel(String(localized: "资料表格"))
            self.table = table
            let scroll = BrowseScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            reload()
            observeModel()
            return scroll
        }

        private func observeModel() {
            withObservationTracking {
                _ = model.visibleEntries
                _ = model.openPath
                _ = model.activeSortClauses
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.reload()
                    self.observeModel()
                }
            }
        }

        func reload() {
            guard let table else { return }
            updating = true
            defer { updating = false }
            var selected = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].path : nil })
            let openPath = model.openPath
            let openedAnotherEntry = openPath != lastOpenPath
            if openedAnotherEntry || selected.isEmpty {
                if let openPath, !selected.contains(openPath) { selected = [openPath] }
                if openPath == nil { selected = [] }
                lastOpenPath = openPath
            }
            let next = model.visibleEntries
            if entries != next {
                entries = next
                table.reloadData()
            }
            let indexes = IndexSet(entries.indices.filter { selected.contains(entries[$0].path) })
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
            if openedAnotherEntry, let row = indexes.first { table.scrollRowToVisible(row) }
            for column in table.tableColumns {
                guard let field = SortField(rawValue: column.identifier.rawValue) else { continue }
                column.sortDescriptorPrototype = model.isPinnedListContext ? nil
                    : NSSortDescriptor(key: field.rawValue, ascending: field.defaultDir == .asc)
            }
            let descriptors = (model.isPinnedListContext ? [] : model.activeSortClauses).map {
                NSSortDescriptor(key: $0.field.rawValue, ascending: $0.dir == .asc)
            }
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard entries.indices.contains(row), let column = tableColumn,
                  let field = SortField(rawValue: column.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = column.identifier
                let text = NSTextField(labelWithString: "")
                text.font = .systemFont(ofSize: 13)
                text.lineBreakMode = .byTruncatingTail
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            let entry = entries[row]
            let value: String
            switch field {
            case .title: value = entry.title ?? (entry.path as NSString).lastPathComponent
            case .author: value = entry.author.joined(separator: ", ")
            case .year: value = entry.year ?? ""
            case .rating: value = entry.ratingScore == 0 ? "" : entry.ratingScore.formatted()
            case .added, .updated:
                value = (field == .added ? entry.added : entry.mtime).map {
                    Date(timeIntervalSince1970: $0).formatted(date: .numeric, time: .omitted)
                } ?? ""
            }
            cell.textField?.stringValue = value
            cell.toolTip = value
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, table.selectedRowIndexes.count == 1,
                  entries.indices.contains(table.selectedRow) else { return }
            let path = entries[table.selectedRow].path
            guard model.openPath != path else { return }
            Task { await model.activateVisibleEntry(path) }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, !model.isPinnedListContext else { return }
            model.setSort(tableView.sortDescriptors.compactMap { descriptor in
                guard let key = descriptor.key, let field = SortField(rawValue: key) else { return nil }
                return SortClause(field: field, dir: descriptor.ascending ? .asc : .desc)
            })
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard entries.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString("entry:\(entries[row].path)", forType: SidebarDragPasteboard.tabItem)
            return item
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            for item in menu.items {
                if let column = item.representedObject as? NSTableColumn {
                    item.state = column.isHidden ? .off : .on
                }
            }
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let column = sender.representedObject as? NSTableColumn else { return }
            column.isHidden.toggle()
            table?.sizeToFit()
            sender.state = column.isHidden ? .off : .on
        }
    }
}
