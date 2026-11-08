import AppKit
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor @Suite(.serialized)
struct EntryListRefreshTests {
    @Test func contentRefreshPreservesSelectionViewportAndUnchangedCells() throws {
        let (model, coordinator, table, scroll) = fixture()
        table.scroll(NSPoint(x: 0, y: 110))
        table.selectRowIndexes(IndexSet([2, 4]), byExtendingSelection: false)
        let untouched = try #require(table.view(atColumn: 0, row: 4, makeIfNecessary: true))
        let origin = scroll.contentView.bounds.origin
        let reloads = table.fullReloads
        model.viewport.visibleEntries[1] = model.visibleEntries[1].with(title: "Renamed")
        model.viewport.visibleEntries[60] = model.visibleEntries[60].with(ratingScore: 5, preview: "New preview")

        coordinator.reload(table)

        #expect(table.fullReloads == reloads)
        #expect(table.partialRows == IndexSet([2, 120]))
        #expect(table.heightRows == IndexSet(integer: 120))
        #expect(table.selectedRowIndexes == IndexSet([2, 4]))
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(table.view(atColumn: 0, row: 4, makeIfNecessary: false) === untouched)
        #expect(table.view(atColumn: 0, row: 120, makeIfNecessary: false) == nil)
        #expect(coordinator.dropEntry(at: 2)?.title == "Renamed")
        #expect(coordinator.dropEntry(at: 120)?.preview == "New preview")
        #expect(table.rect(ofRow: 120).height == 124)
        let partials = table.partialReloads
        coordinator.reload(table)
        #expect(table.partialReloads == partials)
        #expect(table.fullReloads == reloads)
    }

    @Test func reorderAndRowCountChangesKeepFullReloadFallback() {
        let (model, coordinator, table, scroll) = fixture()
        let reloads = table.fullReloads
        model.viewport.visibleEntries.swapAt(0, 1)
        coordinator.reload(table)
        #expect(table.fullReloads == reloads + 1)
        #expect(coordinator.dropEntry(at: 0)?.path == "paper-1.md")
        model.viewport.visibleEntries.removeLast()
        coordinator.reload(table)
        #expect(table.fullReloads == reloads + 2)
        #expect(table.numberOfRows == 157)
        #expect(scroll.documentView === table)
    }

    @Test func matchContentRefreshesLocallyButIdentityAndModeChangesReload() {
        let (model, coordinator, table, scroll) = fixture()
        let path = model.visibleEntries[0].path
        model.viewport.searchMatches = [path: matches("old", ordinal: 0)]
        coordinator.reload(table)
        let reloads = table.fullReloads
        model.viewport.searchMatches[path] = matches("new", ordinal: 0)
        coordinator.reload(table)
        #expect(table.fullReloads == reloads)
        #expect(table.partialRows == IndexSet(integer: 1))
        model.viewport.searchMatches[path] = matches("new", ordinal: 1)
        coordinator.reload(table)
        #expect(table.fullReloads == reloads + 1)
        // Same rows, but switching search mode still needs the full fallback.
        model.viewport.searchMatches = [path: .empty]
        coordinator.reload(table)
        let beforeClear = table.fullReloads
        model.viewport.searchMatches = [:]
        coordinator.reload(table)
        #expect(table.fullReloads == beforeClear + 1)
        #expect(scroll.documentView === table)
    }

    private func matches(_ text: String, ordinal: Int) -> BodyMatches {
        BodyMatches(lines: [.init(lineIndex: 0, excerpt: text, spans: [],
                                  matchOrdinal: ordinal, anchor: text)], totalMatches: 1)
    }

    private func fixture() -> (AppModel, EntryListTable.Coordinator, ListReloadCountingTable, NSScrollView) {
        _ = NSApplication.shared
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        model.viewport.visibleEntries = (0..<80).map {
            Entry(path: "paper-\($0).md", type: .paper, title: "Paper \($0)", author: [],
                  year: nil, ratingScore: 0, themes: [], preview: "Preview", hasPDF: false)
        }
        let coordinator = EntryListTable.Coordinator(model: model)
        let table = ListReloadCountingTable(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let column = NSTableColumn(identifier: .init("entry"))
        column.width = 300
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.allowsMultipleSelection = true
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.tableView = table
        let scroll = NSScrollView(frame: table.frame)
        scroll.documentView = table
        coordinator.reload(table)
        return (model, coordinator, table, scroll)
    }
}

@MainActor
private final class ListReloadCountingTable: NSTableView {
    var fullReloads = 0
    var partialReloads = 0
    var partialRows = IndexSet()
    var heightRows = IndexSet()

    override func reloadData() {
        fullReloads += 1
        super.reloadData()
    }

    override func reloadData(forRowIndexes rows: IndexSet, columnIndexes columns: IndexSet) {
        partialReloads += 1
        partialRows = rows
        super.reloadData(forRowIndexes: rows, columnIndexes: columns)
    }

    override func noteHeightOfRows(withIndexesChanged rows: IndexSet) {
        heightRows = rows
        super.noteHeightOfRows(withIndexesChanged: rows)
    }
}
