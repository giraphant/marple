import AppKit
import SwiftUI
import MarpleKit

/// NSViewRepresentable around NSTableView for the middle browse column.
///
/// **Flat-row architecture (Ulysses-style).** Each entry, each matched line,
/// and each "再显示 N 个" toggle is an independent table row. Keyboard ↑↓
/// walks through header → match 1 → match 2 → match 3 → next header → … —
/// the same behavior the user observed in Ulysses' search panel. This avoids
/// the earlier "row-with-internal-expandable-VStack" model whose `activeMatch
/// Ordinal` highlight, dynamic row height, NSHostingView intrinsic-size hacks,
/// and `selectionHighlightStyle` overrides were all working around the fact
/// that NSTableView's selection lives at the row level, not inside cells.
///
/// **Visual two-layer selection (QUA-95)** falls out for free:
///   • The *open entry's* rows (header + matches + toggle) get a pale-tinted
///     background painted by `EntryGroupRowView.drawBackground`.
///   • Whichever row is currently focused (header OR a specific match) gets
///     the system's standard dark-blue selection on top of that tint.
///
/// **Reentrant warning (QUA-103)** stays fixed: every reload is scheduled
/// through `DispatchQueue.main.async`, observation callbacks dispatch via
/// `Task { @MainActor in }`, and row heights are pure constants (no probe),
/// so SwiftUI never re-enters NSTableView's delegate mid-paint.
struct EntryListTable: NSViewRepresentable {
    var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = BrowseTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.delegate = context.coordinator
        table.registerForDraggedTypes([SidebarDragPasteboard.tabItem])
        table.onClickRow = { [weak coordinator = context.coordinator] row in
            guard let coordinator, let entry = coordinator.dropEntry(at: row) else { return }
            coordinator.model.toggleArchiveCollection(entry.path)
        }
        table.onOpenRow = { [weak coordinator = context.coordinator] row in
            guard let coordinator, let entry = coordinator.dropEntry(at: row) else { return }
            Task { await coordinator.model.open(entry.path) }
        }
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.dataSource = context.coordinator

        table.menuForBackground = { [weak coordinator = context.coordinator] in
            coordinator.flatMap { BrowseEntryMenu.background(model: $0.model) }
        }
        table.menuForRows = { [weak coordinator = context.coordinator] rows in
            coordinator?.contextMenu(for: rows)
        }

        context.coordinator.tableView = table

        let scroll = BrowseScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak table] in
            guard let coordinator, let table else { return }
            coordinator.reload(table)
            coordinator.observeModel()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.scheduleReload(table)
    }

    /// One enum value per table row. Order in the array IS the row order.
    /// `.spacer` rows sit between adjacent entry groups; they're transparent,
    /// non-selectable, skipped by keyboard nav, and exist only to give visual
    /// air between cards while leaving `intercellSpacing = 0` (which is what
    /// lets the in-group rows paint a continuous card without gaps).
    enum RowItem: Equatable {
        case entryHeader(Entry)
        case match(entryPath: String, line: BodyMatchLine)
        case expandToggle(entryPath: String, expanded: Bool, hiddenCount: Int)
        case spacer
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: AppModel
        weak var tableView: NSTableView?

        private var items: [RowItem] = []
        private var lastSearchMode = false
        private var lastSnapshot: SchemaSnapshot?
        private var lastActiveTabID: NavTab.ID?
        private var lastPinnedListContext = false
        private var isUpdatingSelection = false
        private var lastOpenPath: String?
        private var lastMatchJumpID: UUID?

        private enum SelectionKey: Hashable {
            case entry(String)
            case match(String, Int)
        }

        private func selectionKey(_ item: RowItem) -> SelectionKey? {
            switch item {
            case .entryHeader(let entry): return .entry(entry.path)
            case .match(let path, let line): return .match(path, line.matchOrdinal)
            case .spacer, .expandToggle: return nil
            }
        }
        private var pendingReload = false

        private static let headerCellID = NSUserInterfaceItemIdentifier("entry-header-cell")
        private static let matchCellID = NSUserInterfaceItemIdentifier("match-line-cell")
        private static let toggleCellID = NSUserInterfaceItemIdentifier("expand-toggle-cell")
        private static let groupRowID = NSUserInterfaceItemIdentifier("entry-group-row")

        // Row heights are constant per kind — no probe, no cache. The header's
        // SwiftUI body has a fixed 76pt title+preview block (spec §4), so the
        // only header-height variable is whether the meta line is present.
        static let headerHeightWithMeta: CGFloat = 124
        static let headerHeightNoMeta: CGFloat = 100
        static let matchLineHeight: CGFloat = 24
        static let expandToggleHeight: CGFloat = 24
        static let spacerHeight: CGFloat = 10
        static let matchCap = 3

        init(model: AppModel) {
            self.model = model
        }

        /// AppModel is @Observable; track exactly the keys that affect row
        /// layout, then re-arm after each fire and dispatch onto the next
        /// runloop tick. See QUA-101/103 for why we can't touch the table
        /// synchronously inside the observation callback.
        func observeModel() {
            withObservationTracking {
                _ = model.visibleEntries.count
                _ = model.openPath
                _ = model.activeTabID
                _ = model.isPinnedListContext
                _ = model.searchMatchQuery
                _ = model.matchExpanded
                _ = model.matchJump
                _ = model.schemaSnapshot
                for entry in model.visibleEntries {
                    _ = model.searchMatches[entry.path]?.lines.count
                }
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.observeModel()
                    if let table = self.tableView { self.scheduleReload(table) }
                }
            }
        }

        func scheduleReload(_ table: NSTableView) {
            guard !pendingReload else { return }
            pendingReload = true
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table else { return }
                self.pendingReload = false
                self.reload(table)
            }
        }

        private var lastExpanded: Set<String> = []

        func reload(_ table: NSTableView) {
            let newItems = buildItems()
            let newSearchMode = isInSearchMode
            let contextChanged = model.activeTabID != lastActiveTabID
                || model.isPinnedListContext != lastPinnedListContext
            lastActiveTabID = model.activeTabID
            lastPinnedListContext = model.isPinnedListContext

            let itemsChanged = items != newItems
            // search-mode flip swaps row-view classes (default ↔ group),
            // require a full reloadData even if items happen to compare equal
            let searchModeFlipped = newSearchMode != lastSearchMode
            // conformance dots are computed at configure-time, not encoded in
            // RowItem; a snapshot nil→present/version change with unchanged
            // entries must still repaint, so force a reload on snapshot drift.
            let snapshotChanged = model.schemaSnapshot != lastSnapshot

            if itemsChanged || searchModeFlipped || snapshotChanged || lastExpanded != model.expandedArchiveCollections {
                lastExpanded = model.expandedArchiveCollections
                let wasSearchMode = lastSearchMode
                let selected = Set(table.selectedRowIndexes.compactMap { row in
                    items.indices.contains(row) ? selectionKey(items[row]) : nil
                })
                isUpdatingSelection = true
                items = newItems
                lastSearchMode = newSearchMode
                lastSnapshot = model.schemaSnapshot
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.reloadData()
                table.selectRowIndexes(IndexSet(items.indices.filter { row in
                    selectionKey(items[row]).map { selected.contains($0) } ?? false
                }), byExtendingSelection: false)
                isUpdatingSelection = false
                NSAnimationContext.endGrouping()
                let restoredSelection = syncSelection(in: table, reveal: contextChanged || searchModeFlipped)
                if newSearchMode && !wasSearchMode && !restoredSelection && table.numberOfRows > 0 {
                    table.scrollRowToVisible(0)
                }
                return
            }

            // Items unchanged. Just sync selection — that triggers
            // tableViewSelectionDidChange → refreshGroupHighlight if the
            // selection target actually moves.
            syncSelection(in: table, reveal: contextChanged)
        }

        private var isInSearchMode: Bool {
            !model.searchMatches.isEmpty
        }

        private func buildItems() -> [RowItem] {
            var result: [RowItem] = []
            for (idx, entry) in model.visibleEntries.enumerated() {
                if idx > 0 { result.append(.spacer) }  // gap between adjacent groups
                result.append(.entryHeader(entry))
                guard let matches = model.searchMatches[entry.path],
                      !matches.lines.isEmpty else { continue }
                let expanded = model.matchExpanded.contains(entry.path)
                let visible = expanded ? matches.lines : Array(matches.lines.prefix(Self.matchCap))
                for line in visible {
                    result.append(.match(entryPath: entry.path, line: line))
                }
                if matches.lines.count > Self.matchCap {
                    result.append(.expandToggle(
                        entryPath: entry.path,
                        expanded: expanded,
                        hiddenCount: matches.lines.count - Self.matchCap
                    ))
                }
            }
            return result
        }

        private func ownerEntryPath(of item: RowItem) -> String? {
            switch item {
            case .entryHeader(let entry): return entry.path
            case .match(let path, _): return path
            case .expandToggle(let path, _, _): return path
            case .spacer: return nil
            }
        }

        /// Group highlight tracks the **table's current selection owner**, not
        /// `model.openPath`. Selection changes are synchronous in AppKit (the
        /// `tableViewSelectionDidChange` notification fires right after
        /// `selectRowIndexes` or a user click), whereas `model.openPath`
        /// propagation has to round-trip through async `model.open` →
        /// observation → scheduled reload — one runloop hop of lag. Tying the
        /// highlight to selection instead of openPath kills the "上面残留下面
        /// 晚变色" flicker on card-to-card switches.
        private func currentSelectionOwner(in table: NSTableView) -> String? {
            let sel = table.selectedRow
            guard sel >= 0 && sel < items.count else { return nil }
            return ownerEntryPath(of: items[sel])
        }

        /// Refresh `isOpenEntry` across visible rows (no reloadData). Called
        /// from `tableViewSelectionDidChange` so the swap is synchronous with
        /// the selection notification — group bg snaps from old → new card in
        /// the same frame the system selection paint moves.
        private func refreshGroupHighlight(in table: NSTableView) {
            let visibleRange = table.rows(in: table.visibleRect)
            guard visibleRange.length > 0 else { return }
            let selectedOwner = currentSelectionOwner(in: table)
            for rowIndex in visibleRange.location..<(visibleRange.location + visibleRange.length) {
                guard rowIndex >= 0 && rowIndex < items.count,
                      let rowView = table.rowView(atRow: rowIndex, makeIfNecessary: false) as? EntryGroupRowView
                else { continue }
                let owner = ownerEntryPath(of: items[rowIndex])
                rowView.isOpenEntry = (owner != nil && owner == selectedOwner)
            }
        }

        @discardableResult
        private func syncSelection(in table: NSTableView, reveal: Bool = false) -> Bool {
            let openedAnotherEntry = model.openPath != lastOpenPath
            let jumpedToMatch = model.matchJump?.id != lastMatchJumpID
            lastOpenPath = model.openPath
            lastMatchJumpID = model.matchJump?.id
            // A normal refresh must not collapse a native range/Command selection,
            // nor reselect a row the user explicitly deselected.
            guard openedAnotherEntry || jumpedToMatch || reveal else {
                refreshGroupHighlight(in: table)
                return !table.selectedRowIndexes.isEmpty
            }
            let target: Int = {
                guard let path = model.openPath else { return -1 }
                // Prefer the match row whose ordinal == matchJump.ordinal, if
                // there's a live matchJump on the current query.
                if let jump = model.matchJump, jump.query == model.searchMatchQuery {
                    if let idx = items.firstIndex(where: { item in
                        if case .match(let p, let line) = item,
                           p == path, line.matchOrdinal == jump.ordinal {
                            return true
                        }
                        return false
                    }) { return idx }
                }
                return items.firstIndex(where: { item in
                    if case .entryHeader(let entry) = item, entry.path == path {
                        return true
                    }
                    return false
                }) ?? -1
            }()
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }
            if target >= 0 {
                // A click may finish opening a tab after the user has already
                // extended the selection. Revealing that same selected item
                // must not collapse the user's multi-selection.
                if !table.selectedRowIndexes.contains(target) || jumpedToMatch || (reveal && table.selectedRowIndexes.count <= 1) {
                    table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                    table.scrollRowToVisible(target)
                } else if reveal {
                    table.scrollRowToVisible(target)
                }
            } else if table.selectedRow >= 0 {
                table.deselectAll(nil)
            }
            return target >= 0
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < items.count else { return nil }
            switch items[row] {
            case .entryHeader(let entry):
                let cell = tableView.makeView(withIdentifier: Self.headerCellID, owner: self) as? EntryHeaderCell
                    ?? EntryHeaderCell()
                cell.identifier = Self.headerCellID
                cell.configure(entry: entry, collectionExpanded: model.archiveCollection(at: entry.path).map { model.expandedArchiveCollections.contains($0.path) } ?? false, indented: model.archiveMemberIndent(entry.path),
                               nonConforming: !entry.isArchiveCollection && model.conformance(for: entry)?.isConforming == false)
                return cell
            case .match(_, let line):
                let cell = tableView.makeView(withIdentifier: Self.matchCellID, owner: self) as? MatchLineCell
                    ?? MatchLineCell()
                cell.identifier = Self.matchCellID
                cell.configure(line: line)
                return cell
            case .expandToggle(let path, let expanded, let hidden):
                let cell = tableView.makeView(withIdentifier: Self.toggleCellID, owner: self) as? ExpandToggleCell
                    ?? ExpandToggleCell()
                cell.identifier = Self.toggleCellID
                cell.configure(expanded: expanded, hiddenCount: hidden) { [weak self] in
                    self?.model.toggleMatchExpanded(path)
                }
                return cell
            case .spacer:
                return nil  // transparent row, no cell content needed
            }
        }

        /// `EntryGroupRowView` wraps every non-spacer row so it can paint the
        /// corner-aware card background when its owner entry is open. Position
        /// in group (first / last / middle) drives the corner radii — together
        /// with `intercellSpacing = 0`, that's the entire "spans-multiple-rows
        /// rounded card" hack (see file header).
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row >= 0 && row < items.count else { return nil }
            if case .spacer = items[row] { return nil }  // transparent default row

            let view = tableView.makeView(withIdentifier: Self.groupRowID, owner: self) as? EntryGroupRowView
                ?? EntryGroupRowView()
            view.identifier = Self.groupRowID
            let owner = ownerEntryPath(of: items[row])
            view.ownerEntryPath = owner
            // Highlight tracks table selection (synchronous) not openPath
            // (one-runloop-hop async). See refreshGroupHighlight for rationale.
            let selectedOwner = currentSelectionOwner(in: tableView)
            view.isOpenEntry = (owner != nil && owner == selectedOwner)
            view.isFirstInGroup = isFirstInGroup(row: row)
            view.isLastInGroup = isLastInGroup(row: row)
            return view
        }

        /// First row of a group = previous row is in a different group (or
        /// there is no previous row). `.spacer` rows have nil owner so any
        /// boundary across a spacer counts as a group break.
        private func isFirstInGroup(row: Int) -> Bool {
            guard row > 0 else { return true }
            let here = ownerEntryPath(of: items[row])
            let prev = ownerEntryPath(of: items[row - 1])
            return here != prev
        }

        private func isLastInGroup(row: Int) -> Bool {
            guard row < items.count - 1 else { return true }
            let here = ownerEntryPath(of: items[row])
            let next = ownerEntryPath(of: items[row + 1])
            return here != next
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0 && row < items.count else { return 60 }
            switch items[row] {
            case .entryHeader(let entry):
                return rowHasMeta(entry) ? Self.headerHeightWithMeta : Self.headerHeightNoMeta
            case .match:
                return Self.matchLineHeight
            case .expandToggle:
                return Self.expandToggleHeight
            case .spacer:
                return Self.spacerHeight
            }
        }

        /// Expand toggle is a clickable button-row; it shouldn't ever sit in
        /// the selection (keyboard ↑↓ skips it, matching Ulysses' behavior
        /// where ↓ goes card → match-1 → match-2 → match-3 → next-card,
        /// never landing on a "+N more" affordance). Spacer is the same idea.
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row >= 0 && row < items.count else { return false }
            switch items[row] {
            case .entryHeader, .match: return true
            case .expandToggle, .spacer: return false
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            // Group highlight tracks selection — refresh on EVERY selection
            // change (user-driven AND programmatic) so the new card's pale
            // bg paints in the same frame the system selection moves there.
            refreshGroupHighlight(in: table)

            // Programmatic selection (syncSelection) shouldn't re-trigger
            // model.open / openMatchedLine — that would be a feedback loop.
            guard !isUpdatingSelection, table.selectedRowIndexes.count == 1 else { return }
            let row = table.selectedRow
            guard row >= 0 && row < items.count else { return }
            switch items[row] {
            case .entryHeader(let entry):
                if model.openPath != entry.path {
                    Task { await model.activateVisibleEntry(entry.path) }
                }
            case .match(let path, let line):
                Task {
                    await model.openMatchedLine(
                        path: path,
                        query: model.searchMatchQuery,
                        ordinal: line.matchOrdinal,
                        anchor: line.anchor)
                }
            case .expandToggle, .spacer:
                break  // shouldSelectRow returns false; unreachable
            }
        }

        private func rowHasMeta(_ entry: Entry) -> Bool {
            if !entry.author.isEmpty { return true }
            if let y = entry.year, !y.isEmpty { return true }
            if entry.ratingScore > 0 { return true }
            if entry.hasPDF { return true }
            return false
        }

        func dropEntry(at row: Int) -> Entry? {
            guard items.indices.contains(row), case .entryHeader(let entry) = items[row] else { return nil }
            return entry
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            let targetRow = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
            guard let entry = dropEntry(at: targetRow), ArchiveEntryDrop.paths(info.draggingPasteboard, onto: entry, model: model) != nil else { return [] }
            tableView.setDropRow(targetRow, dropOperation: .on)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let entry = dropEntry(at: row) else { return false }
            return ArchiveEntryDrop.accept(info.draggingPasteboard, onto: entry, model: model)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard items.indices.contains(row), case .entryHeader(let entry) = items[row], entry.type == .archive else { return nil }
            let item = NSPasteboardItem()
            item.setString("entry:\(entry.path)", forType: SidebarDragPasteboard.tabItem)
            return item
        }

        func contextMenu(for rows: IndexSet) -> NSMenu? {
            let paths = Set(rows.compactMap { row in
                items.indices.contains(row) ? ownerEntryPath(of: items[row]) : nil
            })
            return BrowseEntryMenu.make(entries: model.visibleEntries.filter { paths.contains($0.path) }, model: model)
        }

    }
}

// MARK: - Row view

/// Corner-aware row background that lets multiple adjacent rows visually fuse
/// into a single rounded card. The "hack" the user identified — each row paints
/// only half the corners; with `intercellSpacing = 0` between in-group rows
/// they butt up perfectly into one continuous shape:
///
///   • single row in a group (`first && last`): all four corners rounded
///   • first row of a multi-row group: top corners only
///   • middle row: no rounding (straight edges that meet the neighbours)
///   • last row of a multi-row group: bottom corners only
///
/// Visual gap *between* groups comes from `.spacer` rows in `items[]` (no
/// owner, no paint, transparent — system background shows through).
@MainActor
private final class EntryGroupRowView: NSTableRowView {
    var ownerEntryPath: String?
    var isOpenEntry = false {
        didSet { if oldValue != isOpenEntry { needsDisplay = true } }
    }
    var isFirstInGroup = false {
        didSet { if oldValue != isFirstInGroup { needsDisplay = true } }
    }
    var isLastInGroup = false {
        didSet { if oldValue != isLastInGroup { needsDisplay = true } }
    }
    override var isEmphasized: Bool {
        didSet { if oldValue != isEmphasized { needsDisplay = true } }
    }

    private static let cornerRadius: CGFloat = 8
    private static let horizontalInset: CGFloat = 8

    /// Both group background and selection draw from the **same system
    /// selection color**, just at different alpha. When the table is
    /// emphasized (window key + first responder), the source is
    /// `selectedContentBackgroundColor` — the saturated accent. When
    /// unemphasized, it switches to `unemphasizedSelectedContentBackground
    /// Color` — the system pale gray. Both group bg and the selected row
    /// shift in lockstep, matching Ulysses' "blue card when focused, gray
    /// card when unfocused" cycle.
    private var selectionSourceColor: NSColor {
        isEmphasized ? .selectedContentBackgroundColor
                     : .unemphasizedSelectedContentBackgroundColor
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isOpenEntry else { return }
        // Pale tint: the unemphasized system gray is already a low-contrast
        // color, so it needs a higher alpha to read at all; emphasized accent
        // is saturated and works at a lower alpha.
        let alpha: CGFloat = isEmphasized ? 0.20 : 0.55
        selectionSourceColor.withAlphaComponent(alpha).setFill()
        groupPath().fill()
    }

    /// Replaces AppKit's default selection paint so we control the SHAPE
    /// (corner-aware path, matches the group card outline) while letting
    /// the COLOR come from the standard macOS selection colors — same
    /// source as the group bg above, just at full alpha. A selected row
    /// inside a multi-row group reads as part of the same continuous card,
    /// not a separate block.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        selectionSourceColor.setFill()
        groupPath().fill()
    }

    private func groupPath() -> NSBezierPath {
        let rect = bounds.insetBy(dx: Self.horizontalInset, dy: 0)
        let topRadius: CGFloat = isFirstInGroup ? Self.cornerRadius : 0
        let bottomRadius: CGFloat = isLastInGroup ? Self.cornerRadius : 0
        return Self.roundedPath(in: rect, topRadius: topRadius, bottomRadius: bottomRadius)
    }

    /// Build an NSBezierPath with optional top + bottom corner rounding,
    /// using tangent arcs (`appendArc(from:to:radius:)`) so the geometry
    /// works the same way in flipped or non-flipped coordinate systems —
    /// NSTableRowView is flipped by default, and angle-based arc APIs would
    /// reverse direction here. Tangent-arc just rounds whatever corner the
    /// line segments form, regardless of flip.
    private static func roundedPath(in rect: NSRect, topRadius: CGFloat, bottomRadius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let topLeft = NSPoint(x: minX, y: minY)
        let topRight = NSPoint(x: maxX, y: minY)
        let bottomRight = NSPoint(x: maxX, y: maxY)
        let bottomLeft = NSPoint(x: minX, y: maxY)

        // Start just past the top-left corner.
        path.move(to: NSPoint(x: minX + topRadius, y: minY))
        // Top edge → top-right corner.
        if topRadius > 0 {
            path.appendArc(from: topRight, to: bottomRight, radius: topRadius)
        } else {
            path.line(to: topRight)
        }
        // Right edge → bottom-right corner.
        if bottomRadius > 0 {
            path.appendArc(from: bottomRight, to: bottomLeft, radius: bottomRadius)
        } else {
            path.line(to: bottomRight)
        }
        // Bottom edge → bottom-left corner.
        if bottomRadius > 0 {
            path.appendArc(from: bottomLeft, to: topLeft, radius: bottomRadius)
        } else {
            path.line(to: bottomLeft)
        }
        // Left edge → close back to the top-left starting point.
        if topRadius > 0 {
            path.appendArc(from: topLeft, to: topRight, radius: topRadius)
        } else {
            path.line(to: topLeft)
        }
        path.close()
        return path
    }
}

// MARK: - Cells

@MainActor
private final class EntryHeaderCell: NSTableCellView {
    private var hostingView: NSHostingView<EntryRow>?

    func configure(entry: Entry, collectionExpanded: Bool, indented: Bool, nonConforming: Bool) {
        let root = EntryRow(entry: entry, nonConforming: nonConforming, collectionExpanded: collectionExpanded, indented: indented)
        if let view = hostingView {
            view.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            ])
            hostingView = view
        }
    }
}

@MainActor
private final class MatchLineCell: NSTableCellView {
    private var hostingView: NSHostingView<MatchLineView>?

    func configure(line: BodyMatchLine) {
        let root = MatchLineView(line: line)
        if let view = hostingView {
            view.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            ])
            hostingView = view
        }
    }
}

@MainActor
private final class ExpandToggleCell: NSTableCellView {
    private var hostingView: NSHostingView<ExpandToggleView>?

    func configure(expanded: Bool, hiddenCount: Int, onToggle: @escaping () -> Void) {
        let root = ExpandToggleView(expanded: expanded, hiddenCount: hiddenCount, onToggle: onToggle)
        if let view = hostingView {
            view.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            ])
            hostingView = view
        }
    }
}

// MARK: - SwiftUI cell bodies

private struct MatchLineView: View {
    let line: BodyMatchLine

    var body: some View {
        Text(highlighted)
            .font(.system(size: 12, weight: .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var highlighted: AttributedString {
        var astr = AttributedString(line.excerpt)
        astr.foregroundColor = .secondary
        let excerpt = line.excerpt
        for span in line.spans {
            let nsr = NSRange(location: span.location, length: span.length)
            guard let r = Range(nsr, in: excerpt),
                  let lo = AttributedString.Index(r.lowerBound, within: astr),
                  let hi = AttributedString.Index(r.upperBound, within: astr) else { continue }
            astr[lo..<hi].backgroundColor = Color.accentColor.opacity(0.22)
            astr[lo..<hi].foregroundColor = Color.accentColor
        }
        return astr
    }
}

private struct ExpandToggleView: View {
    let expanded: Bool
    let hiddenCount: Int
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(expanded ? String(localized: "收起") : String(localized: "再显示 \(hiddenCount) 个匹配项…"))
                .font(Typo.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
