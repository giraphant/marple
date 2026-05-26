import AppKit
import SwiftUI
import MarpleKit

/// NSViewRepresentable around NSTableView, replacing SwiftUI `List` for the
/// middle browse column. Why direct AppKit:
///
/// 1. **Ulysses two-layer selection (QUA-95)**: `selectionHighlightStyle =
///    .sourceList` produces the pale-blue selection cycle (active = pale blue,
///    unemphasized = pale gray, emphasized via first-responder), which SwiftUI
///    `List` doesn't expose at any preset.
/// 2. **Reentrant warning (QUA-103)**: SwiftUI `List`'s internal NSTableView
///    delegate re-enters on @Observable invalidation during the first paint
///    (lldb-confirmed); owning the table lets us coalesce reloads through
///    `DispatchQueue.main.async` and dispatch observation callbacks on the
///    next runloop turn, which the SwiftUI shell can't.
///
/// Pattern mirrors `SidebarTabOutlineView` (the sibling AppKit-wrap in this
/// codebase). Difference: rows host the existing SwiftUI `EntryRow` via
/// `NSHostingView` so the row content (preview, badges, matched-line buttons)
/// stays declarative; the table only owns selection, focus, and reload.
struct EntryListTable: NSViewRepresentable {
    var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        // We draw selection ourselves via EntryListRowView.drawSelection so we
        // can paint the Ulysses pale-blue tint (active) / gray (unemphasized)
        // cycle. `style = .sourceList` looked promising but on a non-outline
        // NSTableView it doesn't actually switch the selection paint — the row
        // still draws default `.regular` solid dark-blue, swallowing the dark
        // active-line cue inside the row. Custom rowView gives full control.
        table.style = .inset
        table.backgroundColor = .clear
        // SwiftUI List(.inset) used ~8pt visible row separation; match that so
        // the pale-blue source-list selection has visible gutters between rows.
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        // We measure row height ourselves via `tableView(_:heightOfRow:)`.
        // `usesAutomaticRowHeights = true` fed NSHostingView's ideal (single-
        // line) intrinsic size into the row, which collapsed multi-line preview
        // and broke worse the moment search expansion added matched lines.
        // CodeEdit's FindNavigator does the same: probe view + sizeThatFits +
        // per-row cache, invalidated on column width change.
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.tableClicked(_:))
        table.refusesFirstResponder = false

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        table.menu = menu

        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // First paint after the table is in a window: defer to next runloop turn
        // so AppKit's own initial layout pass finishes before we touch
        // selection/reload (the QUA-103 reentrancy root cause was exactly this
        // ordering inside SwiftUI's List).
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

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: AppModel
        weak var tableView: NSTableView?
        private var entries: [Entry] = []
        private var lastExpanded: Set<String> = []
        private var lastMatchLineCounts: [String: Int] = [:]
        /// Tracks whether the previous render was in search mode (any visible row
        /// had a match line). When this flips, row classes change between default
        /// and `EntryListSearchRowView`, so we must `reloadData` even when the
        /// entry array compares equal (edge case: a query that returns the full
        /// pane verbatim).
        private var lastSearchMode = false
        /// Tracks model.openPath across reloads so we know which rows could have
        /// flipped `activeMatchOrdinal` (= which rows actually need re-config).
        /// Cells are otherwise inert to model mutations now that
        /// `EntryListRowHost` no longer uses `@Bindable model`.
        private var lastOpenPath: String?
        /// Fingerprint of `matchJump` (sans the UUID `id`) so a click on the
        /// same matched line twice doesn't trigger an unnecessary cell refresh.
        private var lastMatchJumpKey: String?
        private var isUpdatingSelection = false
        private var pendingReload = false
        /// Row heights only vary by SHAPE — not by per-entry text content, since
        /// `EntryRow`'s title+preview block is a fixed 76pt box. With ~6 unique
        /// shapes across the whole list, this turns search activation from
        /// `O(visible rows) probe runs` into `O(unique shapes) probe runs` —
        /// each shape probed once, all subsequent rows of that shape are
        /// constant-time lookups.
        private struct RowShape: Hashable {
            let hasMeta: Bool
            let visibleMatchedLines: Int  // 0 = non-search; 1+ = search
            let hasExpandButton: Bool      // matched-line count > matchCap
        }
        private var shapeHeightCache: [RowShape: CGFloat] = [:]
        private var measurementWidth: CGFloat = 0
        private var measurementController: NSHostingController<EntryListRowHost>?
        private static let cellIdentifier = NSUserInterfaceItemIdentifier("entry-row-cell")
        private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("entry-row-view")
        private static let minimumRowHeight: CGFloat = 60
        private static let rowHorizontalInset: CGFloat = 12

        init(model: AppModel) {
            self.model = model
        }

        /// AppModel is @Observable; subscribe to the keys that change a row's
        /// content or order, then re-arm after each fire. Dispatch the work on
        /// the next main-runloop tick — never reenter the delegate from within
        /// the observation callback (that was QUA-101 for derived data, and the
        /// SwiftUI List version of the same problem is QUA-103).
        func observeModel() {
            withObservationTracking {
                _ = model.visibleEntries.count
                _ = model.openPath
                _ = model.searchMatchQuery
                _ = model.matchExpanded
                _ = model.matchJump
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

        /// Decide between three reload strategies:
        ///   1. Full `reloadData()` when entries differ — order or per-row
        ///      metadata (title/author/rating/year/hasPDF) changed. Entry is
        ///      Equatable so this catches metadata edits the previous
        ///      path-only signature missed.
        ///   2. `noteHeightOfRows(withIndexesChanged:)` when the visible rows
        ///      are the same but match-expansion or per-entry match-line count
        ///      changed — the row content stays but the row HEIGHT does.
        ///   3. Just `syncSelection` + active-cue refresh otherwise (e.g.
        ///      `openPath` or `matchJump` flipped without any structural
        ///      change).
        func reload(_ table: NSTableView) {
            let newEntries = model.visibleEntries
            let newExpanded = model.matchExpanded
            let newCounts = matchLineCounts(for: newEntries)
            let newSearchMode = !newCounts.isEmpty
            let newOpenPath = model.openPath
            let newMatchJumpKey = matchJumpFingerprint()

            let entriesChanged = entries != newEntries
            // Even if entries compare equal, a search-mode flip requires a full
            // reload so AppKit re-fetches rowViews via `rowViewForRow` and
            // swaps between default `NSTableRowView` ↔ `EntryListSearchRowView`.
            let searchModeFlipped = newSearchMode != lastSearchMode

            if entriesChanged || searchModeFlipped {
                let wasSearchMode = lastSearchMode
                entries = newEntries
                lastExpanded = newExpanded
                lastMatchLineCounts = newCounts
                lastSearchMode = newSearchMode
                lastOpenPath = newOpenPath
                lastMatchJumpKey = newMatchJumpKey
                shapeHeightCache.removeAll(keepingCapacity: true)
                // Suppress implicit scroll/content animations that produced the
                // visible "jitter" on search activation. With duration 0 the
                // transition reads as a single immediate frame instead of a
                // cross-fade plus scroll-offset settle.
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.reloadData()
                NSAnimationContext.endGrouping()
                syncSelection(in: table)
                if newSearchMode && !wasSearchMode {
                    table.scrollRowToVisible(0)
                }
                return
            }

            // Same entry list AND same mode. Three increasingly targeted paths:
            //   1. expansion or match-line counts moved → height + content
            //      changed for visible rows; refresh ALL visible cells +
            //      re-measure heights.
            //   2. openPath or matchJump moved → only the rows that hold those
            //      paths can have a different `activeMatchOrdinal`; refresh
            //      just those two cells.
            //   3. Nothing relevant moved → just sync the AppKit selection to
            //      track openPath (cheap).
            if newExpanded != lastExpanded || newCounts != lastMatchLineCounts {
                lastExpanded = newExpanded
                lastMatchLineCounts = newCounts
                lastOpenPath = newOpenPath
                lastMatchJumpKey = newMatchJumpKey
                shapeHeightCache.removeAll(keepingCapacity: true)
                refreshVisibleHostedViews(in: table)
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<entries.count))
            } else if newOpenPath != lastOpenPath || newMatchJumpKey != lastMatchJumpKey {
                let previousOpenPath = lastOpenPath
                lastOpenPath = newOpenPath
                lastMatchJumpKey = newMatchJumpKey
                refreshRowsForOpenPathChange(previous: previousOpenPath, current: newOpenPath, in: table)
            }
            syncSelection(in: table)
        }

        private func matchJumpFingerprint() -> String {
            guard let jump = model.matchJump else { return "" }
            return "\(jump.query)|\(jump.ordinal)|\(jump.anchor)"
        }

        private func matchLineCounts(for entries: [Entry]) -> [String: Int] {
            var counts: [String: Int] = [:]
            for entry in entries {
                if let n = model.searchMatches[entry.path]?.lines.count, n > 0 {
                    counts[entry.path] = n
                }
            }
            return counts
        }

        private func refreshVisibleHostedViews(in table: NSTableView) {
            let visibleRange = table.rows(in: table.visibleRect)
            guard visibleRange.length > 0 else { return }
            for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
                guard row >= 0 && row < entries.count,
                      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? EntryHostingCell
                else { continue }
                cell.configure(host: makeRowHost(for: entries[row]))
            }
        }

        /// Refresh only the rows whose `activeMatchOrdinal` could have flipped
        /// (the previously open path's row + the now-open path's row). Avoids
        /// repainting every visible cell on each click — which was the
        /// "微微抖动" the user saw on every selection change.
        private func refreshRowsForOpenPathChange(previous: String?, current: String?, in table: NSTableView) {
            var touchedRows = Set<Int>()
            for path in [previous, current] {
                guard let path,
                      let idx = entries.firstIndex(where: { $0.path == path })
                else { continue }
                touchedRows.insert(idx)
            }
            for row in touchedRows {
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? EntryHostingCell
                else { continue }
                cell.configure(host: makeRowHost(for: entries[row]))
            }
        }

        /// Build a fully-resolved row host snapshot for `entry` from the current
        /// model state. All inputs are values — once handed to the cell, the
        /// host doesn't observe AppModel, so unrelated model mutations don't
        /// trigger a re-layout.
        private func makeRowHost(for entry: Entry) -> EntryListRowHost {
            let searching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
            let matches: BodyMatches? = searching ? model.searchMatches[entry.path] : nil
            let expanded = model.matchExpanded.contains(entry.path)
            let activeOrdinal: Int? = {
                // matchJump survives until the next match-line click or until
                // search is cleared, so an "A" jump can outlive the user moving
                // on to query "B". Gate by the producing query so an old jump
                // doesn't claim an active row in a different query's results.
                guard model.openPath == entry.path,
                      let jump = model.matchJump,
                      jump.query == model.searchMatchQuery
                else { return nil }
                return jump.ordinal
            }()
            let path = entry.path
            return EntryListRowHost(
                entry: entry,
                matches: matches,
                expanded: expanded,
                activeMatchOrdinal: activeOrdinal,
                onToggleExpand: { [weak self] in
                    self?.model.toggleMatchExpanded(path)
                },
                onMatchTap: { [weak self] line in
                    guard let self else { return }
                    let query = self.model.searchMatchQuery
                    Task { await self.model.openMatchedLine(
                        path: path, query: query,
                        ordinal: line.matchOrdinal, anchor: line.anchor)
                    }
                }
            )
        }

        private func syncSelection(in table: NSTableView) {
            let targetRow: Int = {
                guard let path = model.openPath else { return -1 }
                return entries.firstIndex(where: { $0.path == path }) ?? -1
            }()
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }
            if targetRow >= 0 {
                if table.selectedRow != targetRow {
                    table.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
                    table.scrollRowToVisible(targetRow)
                }
            } else if table.selectedRow >= 0 {
                table.deselectAll(nil)
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < entries.count else { return nil }
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? EntryHostingCell
                ?? EntryHostingCell()
            cell.identifier = Self.cellIdentifier
            cell.configure(host: makeRowHost(for: entries[row]))
            return cell
        }

        /// Two-class split for selection visuals (QUA-95):
        ///   • **Non-search rows** → return `nil`; AppKit creates a default
        ///     `NSTableRowView` and paints the standard emphasized selection
        ///     (solid system blue, text auto-flipped to white). No custom code,
        ///     no behaviour to maintain.
        ///   • **Search-result rows** → return `EntryListSearchRowView`, which
        ///     paints the Ulysses pale-blue tint and keeps `interiorBackgroundStyle`
        ///     at `.normal` so the SwiftUI body's text stays dark on the light
        ///     selection. The dark active-matched-line accent inside the row then
        ///     reads cleanly against the pale tint.
        ///
        /// Single responsibility per class — no `if isSearchMode` branches scattered
        /// across `drawSelection` / `interiorBackgroundStyle` / configure paths.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row >= 0 && row < entries.count else { return nil }
            guard model.searchMatches[entries[row].path] != nil else {
                return nil  // default NSTableRowView, system selection
            }
            let view = tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: self) as? EntryListSearchRowView
            if let view { return view }
            let fresh = EntryListSearchRowView()
            fresh.identifier = Self.rowViewIdentifier
            return fresh
        }

        /// Measure each row at the actual column width. `usesAutomaticRowHeights`
        /// fed NSHostingView's ideal (single-line) intrinsic size to the table,
        /// which collapsed multi-line preview and broke worse with search-expand.
        /// Cache by SHAPE (not by entry) — `EntryRow`'s title+preview block is
        /// a fixed 76pt box, so all rows of the same shape have identical height
        /// regardless of their text content. Search activation goes from 20×
        /// probe runs to 1-2× probe runs.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0 && row < entries.count else { return Self.minimumRowHeight }
            let entry = entries[row]
            let columnWidth = tableView.tableColumns.first?.width ?? tableView.bounds.width
            if abs(columnWidth - measurementWidth) > 0.5 {
                shapeHeightCache.removeAll(keepingCapacity: true)
                measurementWidth = columnWidth
            }
            let shape = rowShape(for: entry)
            if let cached = shapeHeightCache[shape] { return cached }

            let availableWidth = max(columnWidth - Self.rowHorizontalInset * 2, 100)
            let probeHost = makeRowHost(for: entry)
            let controller: NSHostingController<EntryListRowHost>
            if let existing = measurementController {
                existing.rootView = probeHost
                controller = existing
            } else {
                let c = NSHostingController(rootView: probeHost)
                measurementController = c
                controller = c
            }
            // NSHostingController.sizeThatFits(in:) is the documented "what
            // height does the SwiftUI body want at this width" API. The
            // NSHostingView intrinsicContentSize / fittingSize path returned
            // the IDEAL size (Text treated as infinite-width, never wrapping),
            // which was why lineLimit(2-3) was collapsing every row to one line.
            let target = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)
            let measured = controller.sizeThatFits(in: target).height
            let height = max(measured, Self.minimumRowHeight)
            shapeHeightCache[shape] = height
            return height
        }

        private func rowShape(for entry: Entry) -> RowShape {
            let total = lastMatchLineCounts[entry.path] ?? 0
            let expanded = lastExpanded.contains(entry.path)
            let matchCap = 3  // mirror EntryRow.matchCap
            let visible: Int = {
                guard total > 0 else { return 0 }
                return expanded ? total : min(total, matchCap)
            }()
            return RowShape(
                hasMeta: rowHasMeta(entry),
                visibleMatchedLines: visible,
                hasExpandButton: total > matchCap
            )
        }

        private func rowHasMeta(_ entry: Entry) -> Bool {
            if let a = entry.author, !a.isEmpty { return true }
            if let y = entry.year, !y.isEmpty { return true }
            if entry.ratingScore > 0 { return true }
            if entry.hasPDF { return true }
            return false
        }

        // MARK: NSTableViewDelegate

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection,
                  let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow
            guard row >= 0 && row < entries.count else { return }
            let path = entries[row].path
            guard model.openPath != path else { return }
            Task { await model.open(path) }
        }

        @objc fileprivate func tableClicked(_ sender: NSTableView) {
            // Single-click already changes selection (handled in selectionDidChange).
            // Keep this hook free for any future single-click-only behavior.
        }

        /// Column-width changes (sidebar drag, window resize via autoresizing)
        /// invalidate every cached row height since wrap-points move. Wipe the
        /// cache and tell AppKit to re-query heights.
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = tableView else { return }
            shapeHeightCache.removeAll(keepingCapacity: true)
            measurementWidth = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<entries.count))
        }

        // MARK: NSMenuDelegate

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }
            // Right-click clamps selection to clicked row when it's not part of
            // the current selection, so clickedRow is the source of truth.
            let row = table.clickedRow
            guard row >= 0 && row < entries.count else { return }
            let entry = entries[row]
            menu.addItem(menuItem("在新页面页打开", action: #selector(openInNewTabFromMenu(_:)), path: entry.path))
            menu.addItem(menuItem("新建批注", action: #selector(newAnnotationFromMenu(_:)), path: entry.path))
            menu.addItem(.separator())
            menu.addItem(menuItem("移到回收站", action: #selector(moveToTrashFromMenu(_:)), path: entry.path))
        }

        private func menuItem(_ title: String, action: Selector, path: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = path
            return item
        }

        @objc private func openInNewTabFromMenu(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            Task { await model.openInNewTab(path) }
        }

        @objc private func newAnnotationFromMenu(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String,
                  let entry = entries.first(where: { $0.path == path }) else { return }
            Task { await model.newAnnotation(for: entry) }
        }

        @objc private func moveToTrashFromMenu(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            Task { await model.moveToTrash(path) }
        }
    }
}

/// Search-mode row visual (QUA-95): Ulysses two-layer selection.
/// Only allocated for rows whose entry has search matches — non-search rows
/// take the default NSTableRowView path (see `rowViewForRow`), so we never
/// need to ask "am I a search row?" inside this class.
///
///   • **emphasized** (window key + table is first responder) → accent tint
///     (pale blue at ~18% opacity, follows the user's macOS accent color)
///   • **unemphasized** (focus lives elsewhere) → system unemphasized gray
///
/// `interiorBackgroundStyle` is pinned to `.normal` so NSTableCellView's
/// auto-propagation doesn't flip SwiftUI `.primary`/`.secondary` text colors
/// to their light variants — they'd be invisible on the pale tint.
@MainActor
private final class EntryListSearchRowView: NSTableRowView {
    override var isEmphasized: Bool {
        didSet { if oldValue != isEmphasized { needsDisplay = true } }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let color: NSColor = isEmphasized
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        // Slight horizontal inset so selection reads as a "card on paper"
        // rather than running flush to the column edges.
        let rect = bounds.insetBy(dx: 4, dy: 0)
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}

/// Row cell: an NSHostingView wrapping the SwiftUI EntryRow plus the
/// per-matched-line active cue. Keeping `model` as a `@Bindable` lets the row
/// observe matchJump / matchExpanded inside the SwiftUI body — no manual
/// invalidation needed when those flip.
@MainActor
private final class EntryHostingCell: NSTableCellView {
    private var hostingView: NSHostingView<EntryListRowHost>?

    func configure(host: EntryListRowHost) {
        if let view = hostingView {
            view.rootView = host
        } else {
            let view = NSHostingView(rootView: host)
            view.sizingOptions = .intrinsicContentSize
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
            hostingView = view
        }
    }
}

/// Pure value-driven row host. `@Bindable model` used to live here — and any
/// AppModel mutation (e.g. clicking a card → `openPath` changes) would
/// invalidate every visible cell, re-evaluate every body, recreate every
/// closure, and force NSHostingView to re-lay out the whole row. That's the
/// "微微抖动" visible on every selection click. Now the cell receives a fully
/// resolved snapshot at configure time; only the cells the coordinator
/// explicitly re-configures actually re-render.
struct EntryListRowHost: View {
    let entry: Entry
    let matches: BodyMatches?
    let expanded: Bool
    let activeMatchOrdinal: Int?
    let onToggleExpand: () -> Void
    let onMatchTap: (BodyMatchLine) -> Void

    var body: some View {
        EntryRow(
            entry: entry,
            matches: matches,
            expanded: expanded,
            activeMatchOrdinal: activeMatchOrdinal,
            onToggleExpand: onToggleExpand,
            onMatchTap: onMatchTap
        )
    }
}
