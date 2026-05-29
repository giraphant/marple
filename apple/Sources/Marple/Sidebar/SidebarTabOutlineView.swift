import AppKit
import SwiftUI
import MarpleKit

private enum SidebarOutlineSection {
    case objects
    case tabs

    var title: String {
        switch self {
        case .objects: return "物件"
        case .tabs:    return "页面"
        }
    }
}

private final class SidebarOutlineNode: NSObject {
    enum Kind {
        case section(SidebarOutlineSection)
        case pane(Pane)
        case tab(NavTab.ID)
        case group(TabGroup.ID)
    }

    let kind: Kind
    let title: String
    let count: Int?
    let iconName: String?
    let pinned: Bool
    let entryType: EntryType?
    var children: [SidebarOutlineNode]

    init(kind: Kind, title: String, count: Int? = nil, iconName: String? = nil,
         pinned: Bool = false, entryType: EntryType? = nil, children: [SidebarOutlineNode] = []) {
        self.kind = kind
        self.title = title
        self.count = count
        self.iconName = iconName
        self.pinned = pinned
        self.entryType = entryType
        self.children = children
    }

    var payload: String? {
        switch kind {
        case .tab(let id):
            return "tab:\(id.uuidString)"
        case .group(let id):
            return "group:\(id.uuidString)"
        case .pane(.type(let type)):
            return "type:\(type.rawValue)"
        case .section, .pane:
            return nil
        }
    }

    var firstTabID: NavTab.ID? {
        switch kind {
        case .tab(let id): return id
        case .group, .section: return children.first?.firstTabID
        case .pane: return nil
        }
    }

    var isTabsSection: Bool {
        if case .section(.tabs) = kind { return true }
        return false
    }
}

private enum SidebarTabPayload {
    case tab(NavTab.ID)
    case group(TabGroup.ID)
    case type(EntryType)

    init?(_ raw: String?) {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "tab":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .tab(id)
        case "group":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .group(id)
        case "type":
            self = .type(EntryType(rawValue: parts[1]))
        default:
            return nil
        }
    }
}

struct SidebarOutlineView: NSViewRepresentable {
    var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear
        outline.allowsMultipleSelection = true
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.outlineDoubleClicked(_:))
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        outline.menu = menu
        context.coordinator.outlineView = outline
        outline.registerForDraggedTypes([Coordinator.pasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.reload(outline)
        context.coordinator.observeModel()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        if let outline = scroll.documentView as? NSOutlineView {
            context.coordinator.scheduleReload(outline)
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        static let pasteboardType = NSPasteboard.PasteboardType("com.marple.sidebar-tab-item")

        var model: AppModel
        weak var outlineView: NSOutlineView?
        private var rootItems: [SidebarOutlineNode] = []
        private weak var editingField: NSTextField?
        private var editingNode: SidebarOutlineNode?
        private var cancelingRename = false
        private var isUpdatingSelection = false
        private var isRestoringExpansion = false
        private var pendingReload = false
        private var lastReloadSignature: String?
        private var stickyRowDropTarget: SidebarOutlineNode?
        // Row split for tab-on-tab grouping: top/bottom edge bands reorder, the
        // narrow center band triggers grouping. Exit ratio is the hysteresis that
        // keeps a sticky target latched while the cursor jitters.
        private let rowDropEnterEdgeRatio: CGFloat = 0.43
        private let rowDropReleaseEdgeRatio: CGFloat = 0.43
        private let rowDropExitEdgeRatio: CGFloat = 0.12
        private let dndLogging = ProcessInfo.processInfo.environment["MARPLE_DND_LOG"] == "1"

        init(model: AppModel) {
            self.model = model
        }

        func scheduleReload(_ outline: NSOutlineView) {
            guard !pendingReload else { return }
            pendingReload = true
            DispatchQueue.main.async { [weak self, weak outline] in
                guard let self, let outline else { return }
                self.pendingReload = false
                self.reload(outline)
            }
        }

        /// The sidebar lives in an AppKit-hosted SwiftUI column whose body never reads
        /// the model's tab/pane state, so Observation never invalidates it (and thus
        /// `updateNSView` never fires) when tabs are added/closed/reordered. Drive
        /// reloads explicitly, re-armed on each fire — mirrors
        /// `MarpleSplitViewController`'s inspector observation. The read set matches
        /// `reloadSignature()` so every input that changes a row triggers a refresh.
        func observeModel() {
            withObservationTracking {
                _ = model.entries.count
                _ = model.isBrowsing
                _ = model.pane
                _ = model.activeTabID
                _ = model.typeOrder
                _ = model.counts
                _ = model.tabs
                _ = model.tabRootNodes
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.observeModel()
                    if let outline = self.outlineView { self.scheduleReload(outline) }
                }
            }
        }

        func reload(_ outline: NSOutlineView) {
            guard editingNode == nil else { return }
            let signature = reloadSignature()
            guard signature != lastReloadSignature else {
                selectCurrentItem(in: outline)
                return
            }
            // Snapshot the multi-selection by stable payload before reloadData
            // wipes row indices. selectCurrentItem already keeps a multi-row
            // selection that covers the active row across no-op reloads — this
            // extends the same guarantee to structural reloads (QUA-98).
            let preservedPayloads = capturedMultiSelectionPayloads(in: outline)
            lastReloadSignature = signature
            stickyRowDropTarget = nil
            rootItems = makeRootItems()
            outline.reloadData()
            restoreExpansion(in: outline)
            restoreMultiSelection(payloads: preservedPayloads, in: outline)
            selectCurrentItem(in: outline)
        }

        /// Payload set of a multi-row selection (>=2 rows). Returns empty for a
        /// single-row selection — `selectCurrentItem` will re-pick that case
        /// from the active tab/pane on its own.
        private func capturedMultiSelectionPayloads(in outline: NSOutlineView) -> [SidebarTabPayload] {
            let indices = outline.selectedRowIndexes
            guard indices.count > 1 else { return [] }
            return indices.compactMap { row in
                (outline.item(atRow: row) as? SidebarOutlineNode)
                    .flatMap { SidebarTabPayload($0.payload) }
            }
        }

        /// Re-select rows for surviving payloads. Payloads whose row is hidden
        /// (parent group is collapsed) are dropped — respect the user's persisted
        /// collapse state rather than forcing those ancestors open.
        private func restoreMultiSelection(payloads: [SidebarTabPayload], in outline: NSOutlineView) {
            guard payloads.count > 1 else { return }
            var rows = IndexSet()
            for payload in payloads {
                guard let node = findNode(for: payload, in: rootItems) else { continue }
                let row = outline.row(forItem: node)
                if row >= 0 { rows.insert(row) }
            }
            guard rows.count > 1 else { return }
            isUpdatingSelection = true
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            isUpdatingSelection = false
        }

        private func findNode(for payload: SidebarTabPayload, in nodes: [SidebarOutlineNode]) -> SidebarOutlineNode? {
            switch payload {
            case .tab(let id): return findTabNode(id, in: nodes)
            case .group(let id): return findGroupNode(id, in: nodes)
            case .type(let type): return findPaneNode(.type(type), in: nodes)
            }
        }

        private func reloadSignature() -> String {
            var parts: [String] = []
            parts.append("entries:\(model.entries.count)")
            parts.append("browse:\(model.isBrowsing):\(model.pane)")
            parts.append("active:\(model.activeTabID?.uuidString ?? "nil")")
            parts.append("types:\(model.typeOrder.map(String.init(describing:)).joined(separator: ","))")
            parts.append("counts:\(model.typeOrder.map { "\($0)=\(model.counts[$0] ?? 0)" }.joined(separator: ","))")
            parts.append("tabs:\(model.tabs.map { "\($0.id.uuidString):\($0.location):\($0.pinned):\($0.customTitle ?? "")" }.joined(separator: ","))")
            parts.append("tree:\(Self.treeSignature(model.tabRootNodes))")
            return parts.joined(separator: "|")
        }

        private static func treeSignature(_ nodes: [TabNode]) -> String {
            nodes.map { node -> String in
                switch node {
                case .tab(let id):
                    return "t\(id.uuidString)"
                case .group(let g):
                    return "g\(g.id.uuidString):\(g.name):\(g.isCollapsed)[\(treeSignature(g.children))]"
                }
            }.joined(separator: ",")
        }

        private func makeRootItems() -> [SidebarOutlineNode] {
            let entryByPath = Dictionary(model.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            var sections = [
                SidebarOutlineNode(kind: .section(.objects), title: SidebarOutlineSection.objects.title,
                                   children: model.typeOrder.map { type in
                                       SidebarOutlineNode(kind: .pane(.type(type)),
                                                          title: type.label,
                                                          count: model.counts[type] ?? 0,
                                                          iconName: type.symbolName)
                                   })
            ]
            if !model.tabs.isEmpty {
                sections.append(SidebarOutlineNode(kind: .section(.tabs),
                                                   title: SidebarOutlineSection.tabs.title,
                                                   children: makeTabRootItems(entryByPath: entryByPath)))
            }
            return sections
        }

        private func makeTabRootItems(entryByPath: [String: Entry]) -> [SidebarOutlineNode] {
            model.tabRootNodes.compactMap { outlineNode($0, entryByPath: entryByPath) }
        }

        private func outlineNode(_ node: TabNode, entryByPath: [String: Entry]) -> SidebarOutlineNode? {
            switch node {
            case .tab(let id):
                guard let tab = model.tabs.first(where: { $0.id == id }) else { return nil }
                return tabNode(tab, entryByPath: entryByPath)
            case .group(let group):
                return SidebarOutlineNode(kind: .group(group.id),
                                          title: group.name,
                                          count: nil,
                                          iconName: "folder",
                                          children: group.children.compactMap { outlineNode($0, entryByPath: entryByPath) })
            }
        }

        private func tabNode(_ tab: NavTab, entryByPath: [String: Entry]) -> SidebarOutlineNode {
            let entry = tab.location.openPath.flatMap { entryByPath[$0] }
            // QUA-105: during bootstrap entries is empty so `entry?.type` is
            // nil, which would drop the row to the generic list.bullet icon.
            // Fall through to the persisted cachedType so the right type icon
            // (paper / book / note / image / chapter / author) renders from
            // the first frame.
            let resolvedType = entry?.type ?? tab.cachedType
            return SidebarOutlineNode(kind: .tab(tab.id),
                                      title: tabTitle(tab, entry: entry),
                                      iconName: "list.bullet",
                                      pinned: tab.pinned,
                                      entryType: resolvedType)
        }

        private func tabTitle(_ tab: NavTab, entry: Entry?) -> String {
            if let customTitle = tab.customTitle { return customTitle }
            let loc = tab.location
            if let path = loc.openPath {
                if let live = entry?.title { return live }
                if let cached = tab.cachedTitle, !cached.isEmpty { return cached }
                return (path as NSString).lastPathComponent
            }
            switch loc.pane {
            case .type(let type): return type.label
            case .theme(let name): return "#\(name)"
            case .themesIndex: return "标签"
            case .trash: return "回收站"
            }
        }

        private func restoreExpansion(in outline: NSOutlineView) {
            isRestoringExpansion = true
            defer { isRestoringExpansion = false }
            for section in rootItems {
                outline.expandItem(section)
            }
            applyExpansion(to: tabRootItems, in: outline)
        }

        /// Recursively restore each group's expanded/collapsed state. Children rows
        /// only exist once their parent is expanded, so recurse only into expanded
        /// groups.
        private func applyExpansion(to nodes: [SidebarOutlineNode], in outline: NSOutlineView) {
            for node in nodes {
                guard case .group(let id) = node.kind else { continue }
                let collapsed = model.tabGroups.first { $0.id == id }?.isCollapsed ?? false
                if collapsed {
                    outline.collapseItem(node)
                } else {
                    outline.expandItem(node)
                    applyExpansion(to: node.children, in: outline)
                }
            }
        }

        private var tabRootItems: [SidebarOutlineNode] {
            rootItems.first { $0.isTabsSection }?.children ?? []
        }

        private var objectsSection: SidebarOutlineNode? {
            rootItems.first {
                if case .section(.objects) = $0.kind { return true }
                return false
            }
        }

        private func selectCurrentItem(in outline: NSOutlineView) {
            let target: SidebarOutlineNode? = {
                if model.isBrowsing {
                    return findPaneNode(model.pane, in: rootItems)
                }
                guard let active = model.activeTabID else { return nil }
                if let collapsed = model.outermostCollapsedTabGroup(of: active) {
                    return findGroupNode(collapsed, in: rootItems)
                }
                return findTabNode(active, in: rootItems)
            }()
            guard let target else {
                outline.deselectAll(nil)
                return
            }
            let row = outline.row(forItem: target)
            guard row >= 0 else { return }
            // Any multi-row selection (>=2 rows) wins over the single-active
            // default. This covers both the no-op-reload case (selection
            // already on screen) and the structural-reload case where
            // `restoreMultiSelection` just rebuilt the selection from a
            // pre-reload snapshot. Scroll the active row in only if it's
            // already a member of the multi-selection — otherwise nudging
            // the viewport to a non-selected row is a surprise.
            if outline.selectedRowIndexes.count > 1 {
                if outline.selectedRowIndexes.contains(row) {
                    outline.scrollRowToVisible(row)
                }
                return
            }
            isUpdatingSelection = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            isUpdatingSelection = false
        }

        private func findPaneNode(_ pane: Pane, in nodes: [SidebarOutlineNode]) -> SidebarOutlineNode? {
            for node in nodes {
                if case .pane(let p) = node.kind, p == pane { return node }
                if let match = findPaneNode(pane, in: node.children) { return match }
            }
            return nil
        }

        private func findTabNode(_ tabID: NavTab.ID, in nodes: [SidebarOutlineNode]) -> SidebarOutlineNode? {
            for node in nodes {
                if case .tab(let id) = node.kind, id == tabID { return node }
                if let match = findTabNode(tabID, in: node.children) { return match }
            }
            return nil
        }

        private func findGroupNode(_ groupID: TabGroup.ID, in nodes: [SidebarOutlineNode]) -> SidebarOutlineNode? {
            for node in nodes {
                if case .group(let id) = node.kind, id == groupID { return node }
                if let match = findGroupNode(groupID, in: node.children) { return match }
            }
            return nil
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SidebarOutlineNode)?.children.count ?? rootItems.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? SidebarOutlineNode)?.children ?? rootItems)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? SidebarOutlineNode else { return false }
            return !node.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            guard let node = item as? SidebarOutlineNode else { return false }
            if case .section = node.kind { return true }
            return false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? SidebarOutlineNode else { return false }
            if case .section = node.kind { return false }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            guard let node = item as? SidebarOutlineNode else { return true }
            if case .section = node.kind { return false }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? SidebarOutlineNode else { return 30 }
            switch node.kind {
            case .section:
                return 22
            case .pane:
                return 30
            case .tab, .group:
                return 30
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarOutlineNode else { return nil }
            let view = outlineView.makeView(withIdentifier: SidebarOutlineCellView.identifier, owner: self) as? SidebarOutlineCellView
                ?? SidebarOutlineCellView()
            view.configure(node: node, coordinator: self)
            return view
        }

        fileprivate func beginRename(_ node: SidebarOutlineNode, in outlineView: NSOutlineView? = nil) {
            guard canRename(node) else { return }
            let target = liveNode(matching: node) ?? node
            let outline = outlineView ?? self.outlineView
            guard let outline, let row = rowForItem(target, in: outline),
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarOutlineCellView else { return }
            editingNode = target
            editingField = cell.titleField
            cancelingRename = false
            cell.beginEditing(delegate: self)
        }

        private func liveNode(matching node: SidebarOutlineNode) -> SidebarOutlineNode? {
            switch node.kind {
            case .tab(let id): return findTabNode(id, in: rootItems)
            case .group(let id): return findGroupNode(id, in: rootItems)
            case .section, .pane: return node
            }
        }

        private func canRename(_ node: SidebarOutlineNode) -> Bool {
            switch node.kind {
            case .tab, .group: return true
            case .section, .pane: return false
            }
        }

        private func finishRename(commit: Bool) {
            guard let node = editingNode, let field = editingField else { return }
            defer {
                field.isEditable = false
                field.isSelectable = false
                editingNode = nil
                editingField = nil
                cancelingRename = false
                outlineView?.window?.makeFirstResponder(outlineView)
                if let outlineView { reload(outlineView) }
            }
            guard commit else {
                field.stringValue = node.title
                return
            }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch node.kind {
            case .tab(let id):
                model.renameTab(id, to: value)
            case .group(let id):
                if !value.isEmpty { model.renameTabGroup(id, to: value) }
            case .section, .pane:
                break
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard obj.object as? NSTextField === editingField else { return }
            finishRename(commit: !cancelingRename)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelingRename = true
                control.window?.makeFirstResponder(outlineView)
                return true
            }
            return false
        }

        @objc func outlineDoubleClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard row >= 0, let node = sender.item(atRow: row) as? SidebarOutlineNode else { return }
            beginRename(node, in: sender)
        }

        func menuNeedsUpdate(_ contextMenu: NSMenu) {
            contextMenu.removeAllItems()
            guard let outline = outlineView else { return }
            // Right-click on a section header (non-selectable) shouldn't pop a
            // menu over the current selection, which sits elsewhere.
            let clicked = outline.clickedRow
            if clicked >= 0, let clickedNode = outline.item(atRow: clicked) as? SidebarOutlineNode,
               case .section = clickedNode.kind { return }
            // AppKit auto-collapses selection to the clicked row when the clicked
            // row isn't already selected, so `selectedRowIndexes` is the truth.
            let nodes = outline.selectedRowIndexes
                .compactMap { outline.item(atRow: $0) as? SidebarOutlineNode }
                .filter { node in
                    switch node.kind {
                    case .section, .pane: return false
                    case .tab, .group: return true
                    }
                }
            guard !nodes.isEmpty else { return }
            let items: [NSMenuItem] = nodes.count == 1
                ? menuItems(for: nodes[0])
                : batchMenuItems(for: nodes)
            for item in items { contextMenu.addItem(item) }
        }

        /// Build the multi-selection context menu. Always offers "关闭这 N 个";
        /// the new-group action is only shown for a pure-tab selection because the
        /// semantics of grouping a mixed tab/group selection are ambiguous (see
        /// QUA-94 拍板项).
        fileprivate func batchMenuItems(for nodes: [SidebarOutlineNode]) -> [NSMenuItem] {
            let n = nodes.count
            let allTabs = nodes.allSatisfy { if case .tab = $0.kind { return true } else { return false } }
            let tabIDs = collectTabIDs(in: nodes)
            var items: [NSMenuItem] = []

            let closeItem = NSMenuItem(title: "关闭这 \(n) 个", action: #selector(closeBatchFromMenu(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.representedObject = Array(tabIDs) as NSArray
            // Pin-only selection has no actionable closes; reflect that visually.
            let pinned = Set(model.tabs.filter(\.pinned).map(\.id))
            closeItem.isEnabled = !tabIDs.allSatisfy { pinned.contains($0) }
            items.append(closeItem)

            if allTabs {
                let groupItem = NSMenuItem(title: "把这 \(n) 个合成一个新组",
                                           action: #selector(groupBatchFromMenu(_:)), keyEquivalent: "")
                groupItem.target = self
                let pureTabIDs = nodes.compactMap { node -> NavTab.ID? in
                    if case .tab(let id) = node.kind { return id }
                    return nil
                }
                groupItem.representedObject = pureTabIDs as NSArray
                items.append(groupItem)
            }
            return items
        }

        /// Flatten a selection into tab ids: tabs contribute themselves, groups
        /// contribute every descendant tab leaf. Used by batch close.
        private func collectTabIDs(in nodes: [SidebarOutlineNode]) -> [NavTab.ID] {
            var out: [NavTab.ID] = []
            var seen: Set<NavTab.ID> = []
            func append(_ id: NavTab.ID) {
                if seen.insert(id).inserted { out.append(id) }
            }
            for node in nodes {
                switch node.kind {
                case .tab(let id):
                    append(id)
                case .group(let gid):
                    if let group = model.tabGroups.first(where: { $0.id == gid }) {
                        for id in descendantTabIDs(of: group) { append(id) }
                    }
                case .section, .pane:
                    break
                }
            }
            return out
        }

        private func descendantTabIDs(of group: TabGroup) -> [NavTab.ID] {
            var out: [NavTab.ID] = []
            for child in group.children {
                switch child {
                case .tab(let id): out.append(id)
                case .group(let g): out.append(contentsOf: descendantTabIDs(of: g))
                }
            }
            return out
        }

        @objc private func closeBatchFromMenu(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? [Any] else { return }
            let ids = raw.compactMap { $0 as? NavTab.ID }
            guard !ids.isEmpty else { return }
            Task { await model.closeTabs(Set(ids)) }
        }

        @objc private func groupBatchFromMenu(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? [Any] else { return }
            let ids = raw.compactMap { $0 as? NavTab.ID }
            guard ids.count >= 2 else { return }
            model.groupTabs(ids)
        }

        fileprivate func menuItems(for node: SidebarOutlineNode) -> [NSMenuItem] {
            switch node.kind {
            case .group(let id):
                var items = [menuItem("重命名", action: #selector(renameFromMenu(_:)), node: node)]
                if let group = model.tabGroups.first(where: { $0.id == id }) {
                    items.append(menuItem(group.isCollapsed ? "展开页面组" : "折叠页面组",
                                          action: #selector(toggleGroupFromMenu(_:)), node: node))
                }
                return items
            case .tab(let id):
                guard let tab = model.tabs.first(where: { $0.id == id }) else { return [] }
                var items = [menuItem("重命名", action: #selector(renameFromMenu(_:)), node: node)]
                items.append(.separator())
                items.append(menuItem(tab.pinned ? "取消固定" : "固定页面",
                                      action: #selector(togglePinFromMenu(_:)), node: node))
                items.append(.separator())
                let closeItem = menuItem("关闭页面", action: #selector(closeTabFromMenu(_:)), node: node)
                closeItem.isEnabled = model.tabs.count > 1
                items.append(closeItem)
                items.append(menuItem("关闭其他页面", action: #selector(closeOtherTabsFromMenu(_:)), node: node))
                return items
            case .section, .pane:
                return []
            }
        }

        private func menuItem(_ title: String, action: Selector, node: SidebarOutlineNode) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            return item
        }

        @objc private func renameFromMenu(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarOutlineNode else { return }
            beginRename(node)
        }

        @objc private func toggleGroupFromMenu(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarOutlineNode,
                  case .group(let id) = node.kind else { return }
            model.toggleTabGroup(id)
        }

        @objc private func togglePinFromMenu(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarOutlineNode,
                  case .tab(let id) = node.kind else { return }
            model.togglePin(id)
        }

        @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarOutlineNode,
                  case .tab(let id) = node.kind else { return }
            Task { await model.closeTab(id) }
        }

        @objc private func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarOutlineNode,
                  case .tab(let id) = node.kind else { return }
            Task { await model.closeOtherTabs(id) }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection,
                  let outline = notification.object as? NSOutlineView else { return }
            // Multi-select must not steal navigation: only a single-row selection
            // drives the active tab/pane. Shift/Cmd-click leaves the active tab
            // untouched — matches CodeEdit's ProjectNavigator behavior.
            guard outline.selectedRowIndexes.count == 1 else { return }
            let row = outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? SidebarOutlineNode else { return }
            switch node.kind {
            case .pane(let pane):
                model.select(pane: pane)
            case .tab(let id):
                Task { await model.selectTab(id) }
            case .group:
                if let first = node.firstTabID {
                    Task { await model.selectTab(first) }
                }
            case .section:
                break
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isRestoringExpansion,
                  let node = notification.userInfo?["NSObject"] as? SidebarOutlineNode,
                  case .group(let id) = node.kind else { return }
            model.setTabGroup(id, collapsed: false)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isRestoringExpansion,
                  let node = notification.userInfo?["NSObject"] as? SidebarOutlineNode,
                  case .group(let id) = node.kind else { return }
            model.setTabGroup(id, collapsed: true)
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarOutlineNode, let payload = node.payload else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(payload, forType: Self.pasteboardType)
            return pasteboardItem
        }

        /// All `SidebarTabPayload`s carried by the current drag. AppKit packs one
        /// pasteboard item per dragged row; this reads each one rather than the
        /// implicit `string(forType:)` shortcut that only sees the first.
        ///
        /// Ordering: NSOutlineView invokes `pasteboardWriterForItem` for each
        /// selected row in ascending row index (visual top-to-bottom) order, and
        /// items are appended to the pasteboard in that order. QUA-100 relies on
        /// that — if Apple ever changes it, we'd need to re-sort by current row
        /// index at drop time. Behavior is stable as of macOS 14/15.
        private func payloads(from info: NSDraggingInfo) -> [SidebarTabPayload] {
            guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
            return items.compactMap { item in
                item.string(forType: Self.pasteboardType).flatMap(SidebarTabPayload.init)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let allPayloads = payloads(from: info)
            if allPayloads.count > 1 {
                return validateMultiDrop(outlineView, info: info, payloads: allPayloads,
                                         item: item, childIndex: index)
            }
            guard let payload = allPayloads.first
                    ?? SidebarTabPayload(info.draggingPasteboard.string(forType: Self.pasteboardType)) else { return [] }
            let point = draggingPoint(in: outlineView, info: info)
            logDrop("validate proposed=\(describe(item as? SidebarOutlineNode)) index=\(index) row=\(rowAtY(point.y, in: outlineView)) x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y)) sticky=\(describe(stickyRowDropTarget)) payload=\(describe(payload))")
            if case .type = payload {
                return validateTypeDrop(outlineView, info: info, item: item, childIndex: index)
            }
            if shouldRetargetToRow(outlineView, info: info, payload: payload) {
                logDrop("validate retarget sticky=\(describe(stickyRowDropTarget))")
                return .move
            }
            guard let node = item as? SidebarOutlineNode else { return [] }
            switch node.kind {
            case .section(.tabs):
                return .move
            case .group(let targetGroupID):
                // drop-on (center) nests; drop-between reorders/nests at an index.
                // Reject group payloads that would form a cycle (self / descendant).
                if case .group(let sourceID) = payload {
                    return model.canNestGroup(sourceID, into: targetGroupID) ? .move : []
                }
                return .move
            case .tab(let targetID):
                if case .group(let sourceID) = payload, model.groupContainsTab(sourceID, targetID) { return [] }
                // Coerce to drop-on only for tab payloads (the tab-on-tab grouping
                // gesture). Group payloads keep AppKit's between proposal so an edge
                // drop reorders beside the tab instead of grouping onto it.
                if case .tab = payload, index != NSOutlineViewDropOnItemIndex {
                    outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                }
                return .move
            case .section, .pane:
                return []
            }
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            let allPayloads = payloads(from: info)
            if allPayloads.count > 1 {
                let accepted = acceptMultiDrop(outlineView, info: info, payloads: allPayloads,
                                               item: item, childIndex: index)
                stickyRowDropTarget = nil
                if accepted { reload(outlineView) }
                return accepted
            }
            guard let payload = allPayloads.first
                    ?? SidebarTabPayload(info.draggingPasteboard.string(forType: Self.pasteboardType)) else { return false }
            if case .type(let type) = payload {
                let accepted = acceptType(type, into: item as? SidebarOutlineNode, childIndex: index,
                                          outlineView: outlineView, info: info)
                if accepted { reload(outlineView) }
                return accepted
            }
            let point = draggingPoint(in: outlineView, info: info)
            let directTarget = rowDropTarget(outlineView, info: info, payload: payload,
                                            edgeRatio: rowDropReleaseEdgeRatio)
            let stableTarget = stickyRowDropTarget(outlineView, info: info, payload: payload)
            let rememberedTarget = stickyRowDropTarget.flatMap { canDrop(payload, on: $0) ? $0 : nil }
            logDrop("accept proposed=\(describe(item as? SidebarOutlineNode)) index=\(index) row=\(rowAtY(point.y, in: outlineView)) x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y)) direct=\(describe(directTarget)) sticky=\(describe(stableTarget)) remembered=\(describe(rememberedTarget)) payload=\(describe(payload))")
            let accepted: Bool
            if let target = directTarget ?? stableTarget ?? rememberedTarget {
                logDrop("accept row-target=\(describe(target))")
                accepted = accept(payload, into: target, childIndex: NSOutlineViewDropOnItemIndex)
            } else if let node = item as? SidebarOutlineNode {
                switch node.kind {
                case .section(.tabs):
                    accepted = accept(payload, into: nil, childIndex: index)
                case .tab, .group:
                    accepted = accept(payload, into: node, childIndex: index)
                case .section, .pane:
                    accepted = false
                }
            } else {
                accepted = false
            }
            logDrop("accept result=\(accepted)")
            stickyRowDropTarget = nil
            if accepted { reload(outlineView) }
            return accepted
        }

        /// Split payloads into tab/group ids, drop type payloads, apply
        /// "上级胜出". Used by the multi-payload DnD path.
        private func classifyAndFilter(_ payloads: [SidebarTabPayload]) -> (tabs: [NavTab.ID], groups: [TabGroup.ID]) {
            var rawTabs: [NavTab.ID] = []
            var rawGroups: [TabGroup.ID] = []
            for p in payloads {
                switch p {
                case .tab(let id): rawTabs.append(id)
                case .group(let id): rawGroups.append(id)
                case .type: break   // pane reorder doesn't participate in batch DnD
                }
            }
            return model.payloadAncestorFilter(tabIDs: rawTabs, groupIDs: rawGroups)
        }

        /// Same filter as `classifyAndFilter` but preserves the original
        /// payload-sequence order (Finder-style mixed selection — QUA-100).
        /// Type payloads drop out; ancestor filter still drops descendants
        /// whose container is also selected.
        private func orderedItems(_ payloads: [SidebarTabPayload]) -> [WorkspaceItem] {
            let (tabs, groups) = classifyAndFilter(payloads)
            let allowedTabs = Set(tabs)
            let allowedGroups = Set(groups)
            return payloads.compactMap { payload in
                switch payload {
                case .tab(let id): return allowedTabs.contains(id) ? .tab(id) : nil
                case .group(let id): return allowedGroups.contains(id) ? .group(id) : nil
                case .type: return nil
                }
            }
        }

        private func validateMultiDrop(_ outlineView: NSOutlineView, info: NSDraggingInfo,
                                       payloads: [SidebarTabPayload],
                                       item: Any?, childIndex index: Int) -> NSDragOperation {
            let (tabs, groups) = classifyAndFilter(payloads)
            guard !(tabs.isEmpty && groups.isEmpty) else { return [] }
            // Drop on the root tabs section or between rows.
            guard let node = item as? SidebarOutlineNode else { return .move }
            switch node.kind {
            case .section(.tabs):
                return .move
            case .group(let targetGroupID):
                // Reject the whole batch if any group payload would cycle.
                if groups.contains(where: { !model.canNestGroup($0, into: targetGroupID) }) { return [] }
                // Reject if any tab payload is already a descendant of target via
                // a *different* group also in selection — but ancestor filter
                // already pruned that case. So allow.
                return .move
            case .tab(let targetID):
                // Multi-onto-tab only makes sense for a pure-tab batch (forms a
                // new group containing target + dragged tabs).
                guard groups.isEmpty else { return [] }
                guard !tabs.contains(targetID) else { return [] }   // drop onto self
                if index != NSOutlineViewDropOnItemIndex {
                    outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                }
                return .move
            case .section, .pane:
                return []
            }
        }

        private func acceptMultiDrop(_ outlineView: NSOutlineView, info: NSDraggingInfo,
                                     payloads: [SidebarTabPayload],
                                     item: Any?, childIndex index: Int) -> Bool {
            let items = orderedItems(payloads)
            guard !items.isEmpty else { return false }
            logDrop("acceptMulti items=\(items.count) target=\(describe(item as? SidebarOutlineNode)) index=\(index)")
            // Root drop: item is nil OR a .section(.tabs).
            if item == nil
                || (item as? SidebarOutlineNode).map({ if case .section(.tabs) = $0.kind { return true } else { return false } }) == true {
                let safeIndex: Int? = index >= 0 ? index : nil
                model.moveItemsToRoot(items, at: safeIndex)
                return true
            }
            guard let node = item as? SidebarOutlineNode else { return false }
            switch node.kind {
            case .group(let targetGroupID):
                model.moveItems(items, toGroup: targetGroupID, at: index >= 0 ? index : nil)
                return true
            case .tab(let targetID):
                // Pure-tab onto-tab forms a new group of [target, ...dragged].
                // `groupTabs` already DFS-orders, so source visual order is
                // re-resolved to tree position — that's the correct policy for
                // creating a fresh group rather than a flat sequence.
                let tabIDs = items.compactMap { item -> NavTab.ID? in
                    if case .tab(let id) = item { return id }
                    return nil
                }
                guard tabIDs.count == items.count else { return false }
                let combined = [targetID] + tabIDs.filter { $0 != targetID }
                model.groupTabs(combined)
                return true
            case .section, .pane:
                return false
            }
        }

        private func validateTypeDrop(_ outlineView: NSOutlineView, info: NSDraggingInfo,
                                      item: Any?, childIndex index: Int) -> NSDragOperation {
            if let node = item as? SidebarOutlineNode,
               case .section(.objects) = node.kind,
               index >= 0 {
                return .move
            }
            let point = draggingPoint(in: outlineView, info: info)
            let row = rowAtY(point.y, in: outlineView)
            guard row >= 0,
                  let node = outlineView.item(atRow: row) as? SidebarOutlineNode,
                  let objects = objectsSection else { return [] }
            if case .pane(.type(let targetType)) = node.kind,
               let targetIndex = model.typeOrder.firstIndex(of: targetType) {
                let rect = outlineView.rect(ofRow: row)
                let childIndex = point.y < rect.midY ? targetIndex : targetIndex + 1
                outlineView.setDropItem(objects, dropChildIndex: childIndex)
                return .move
            }
            if case .section(.objects) = node.kind {
                outlineView.setDropItem(objects, dropChildIndex: 0)
                return .move
            }
            return []
        }

        private func shouldRetargetToRow(_ outlineView: NSOutlineView, info: NSDraggingInfo,
                                         payload: SidebarTabPayload) -> Bool {
            if let node = rowDropTarget(outlineView, info: info, payload: payload,
                                        edgeRatio: rowDropEnterEdgeRatio) {
                stickyRowDropTarget = node
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return true
            }
            if let node = stickyRowDropTarget(outlineView, info: info, payload: payload) {
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return true
            }
            stickyRowDropTarget = nil
            return false
        }

        private func rowDropTarget(_ outlineView: NSOutlineView, info: NSDraggingInfo,
                                   payload: SidebarTabPayload, edgeRatio: CGFloat) -> SidebarOutlineNode? {
            let point = draggingPoint(in: outlineView, info: info)
            let row = rowAtY(point.y, in: outlineView)
            guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarOutlineNode else { return nil }
            let rect = outlineView.rect(ofRow: row)
            let relativeY = (point.y - rect.minY) / max(rect.height, 1)
            guard relativeY > edgeRatio, relativeY < 1 - edgeRatio else { return nil }
            return canDrop(payload, on: node) ? node : nil
        }

        private func stickyRowDropTarget(_ outlineView: NSOutlineView, info: NSDraggingInfo,
                                         payload: SidebarTabPayload) -> SidebarOutlineNode? {
            guard let node = stickyRowDropTarget, canDrop(payload, on: node) else { return nil }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return nil }
            let point = draggingPoint(in: outlineView, info: info)
            let rect = outlineView.rect(ofRow: row)
            guard point.y >= rect.minY - 4, point.y <= rect.maxY + 4 else { return nil }
            let relativeY = (point.y - rect.minY) / max(rect.height, 1)
            guard relativeY > rowDropExitEdgeRatio, relativeY < 1 - rowDropExitEdgeRatio else { return nil }
            return node
        }

        private func canDrop(_ payload: SidebarTabPayload, on node: SidebarOutlineNode) -> Bool {
            switch (payload, node.kind) {
            case (.tab(let sourceID), .tab(let targetID)) where sourceID != targetID:
                return true
            case (.tab, .group):
                return true
            case (.group(let sourceID), .group(let targetID)) where sourceID != targetID:
                return model.canNestGroup(sourceID, into: targetID)
            case (.group(let sourceID), .tab(let targetID)):
                return !model.groupContainsTab(sourceID, targetID)
            default:
                return false
            }
        }

        private func draggingPoint(in outlineView: NSOutlineView, info: NSDraggingInfo) -> NSPoint {
            outlineView.convert(info.draggingLocation, from: nil)
        }

        private func rowForItem(_ item: Any, in outlineView: NSOutlineView) -> Int? {
            let row = outlineView.row(forItem: item)
            return row >= 0 ? row : nil
        }

        private func rowAtY(_ y: CGFloat, in outlineView: NSOutlineView) -> Int {
            for row in 0..<outlineView.numberOfRows {
                let rect = outlineView.rect(ofRow: row)
                if y >= rect.minY, y <= rect.maxY { return row }
            }
            return -1
        }

        private func logDrop(_ message: String) {
            if dndLogging { print("[marple:dnd] \(message)") }
        }

        private func describe(_ payload: SidebarTabPayload) -> String {
            switch payload {
            case .tab(let id): return "tab(\(id.uuidString.prefix(6)))"
            case .group(let id): return "group(\(id.uuidString.prefix(6)))"
            case .type(let type): return "type(\(type.rawValue))"
            }
        }

        private func describe(_ node: SidebarOutlineNode?) -> String {
            guard let node else { return "nil" }
            switch node.kind {
            case .section(let section): return "section(\(section.title))"
            case .pane(let pane): return "pane(\(pane))"
            case .tab(let id): return "tab(\(id.uuidString.prefix(6)), \(node.title))"
            case .group(let id): return "group(\(id.uuidString.prefix(6)), \(node.title))"
            }
        }

        private func accept(_ payload: SidebarTabPayload, into node: SidebarOutlineNode?, childIndex: Int) -> Bool {
            switch payload {
            case .tab(let sourceID):
                return acceptTab(sourceID, into: node, childIndex: childIndex)
            case .group(let groupID):
                return acceptGroup(groupID, into: node, childIndex: childIndex)
            case .type(let type):
                return acceptType(type, into: node, childIndex: childIndex)
            }
        }

        private func acceptType(_ type: EntryType, into node: SidebarOutlineNode?, childIndex: Int,
                                outlineView: NSOutlineView? = nil, info: NSDraggingInfo? = nil) -> Bool {
            let targetIndex: Int? = {
                guard let node else { return nil }
                if case .section(.objects) = node.kind, childIndex >= 0 {
                    return childIndex
                }
                guard let outlineView, let info,
                      case .pane(.type(let targetType)) = node.kind,
                      let row = rowForItem(node, in: outlineView),
                      let index = model.typeOrder.firstIndex(of: targetType) else { return nil }
                let point = draggingPoint(in: outlineView, info: info)
                return point.y < outlineView.rect(ofRow: row).midY ? index : index + 1
            }()
            guard let targetIndex,
                  let from = model.typeOrder.firstIndex(of: type) else { return false }
            var order = model.typeOrder
            order.remove(at: from)
            let adjustedIndex = from < targetIndex ? targetIndex - 1 : targetIndex
            order.insert(type, at: min(max(adjustedIndex, 0), order.count))
            model.setTypeOrder(order)
            return true
        }

        private func acceptTab(_ sourceID: NavTab.ID, into node: SidebarOutlineNode?, childIndex: Int) -> Bool {
            guard model.tabs.contains(where: { $0.id == sourceID }) else { return false }
            guard let node else {
                model.moveTabToRoot(sourceID, beforeTab: tabRootItem(at: childIndex)?.firstTabID)
                return true
            }
            switch node.kind {
            case .tab(let targetID):
                guard sourceID != targetID else { return false }
                model.groupTab(sourceID, onto: targetID)
                return true
            case .group(let groupID):
                model.moveTab(sourceID, toGroup: groupID, at: childIndex >= 0 ? childIndex : nil)
                return true
            case .section, .pane:
                return false
            }
        }

        private func acceptGroup(_ groupID: TabGroup.ID, into node: SidebarOutlineNode?, childIndex: Int) -> Bool {
            guard model.tabGroups.contains(where: { $0.id == groupID }) else { return false }
            guard let node else {
                // Root-section drop between rows: place at root by index (never nest).
                model.moveGroupToRoot(groupID, at: childIndex >= 0 ? childIndex : nil)
                return true
            }
            switch node.kind {
            case .tab(let targetID):
                guard !model.groupContainsTab(groupID, targetID) else { return false }
                model.moveGroup(groupID, beforeTab: targetID)
                return true
            case .group(let targetGroupID):
                guard groupID != targetGroupID, model.canNestGroup(groupID, into: targetGroupID) else { return false }
                if childIndex < 0 {
                    model.moveGroup(groupID, intoGroup: targetGroupID)   // drop-on: nest at end
                } else {
                    model.moveGroup(groupID, intoGroup: targetGroupID, at: childIndex)
                }
                return true
            case .section, .pane:
                return false
            }
        }

        private func tabRootItem(at index: Int) -> SidebarOutlineNode? {
            guard tabRootItems.indices.contains(index) else { return nil }
            return tabRootItems[index]
        }
    }
}

@MainActor
private final class SidebarOutlineCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-outline-cell")

    private let stack = NSStackView()
    private let iconContainer = NSView()
    private let symbolImageView = NSImageView()
    let titleField = NSTextField()
    private let countField = NSTextField(labelWithString: "")
    private let pinImageView = NSImageView()
    private var badgeView: NSView?
    private var iconCenterYConstraint: NSLayoutConstraint!
    private weak var coordinator: SidebarOutlineView.Coordinator?
    private weak var outlineView: NSOutlineView?
    private var node: SidebarOutlineNode?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        identifier = Self.identifier
        setup()
    }

    func configure(node: SidebarOutlineNode, coordinator: SidebarOutlineView.Coordinator) {
        self.node = node
        self.coordinator = coordinator
        self.outlineView = coordinator.outlineView
        objectValue = node
        titleField.stringValue = node.title
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.delegate = nil
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = font(for: node)
        titleField.textColor = textColor(for: node)

        iconContainer.isHidden = isSection(node)
        configureIcon(for: node)

        if let count = node.count, !isSection(node) {
            countField.stringValue = "\(count)"
            countField.isHidden = false
        } else {
            countField.isHidden = true
        }

        pinImageView.isHidden = !node.pinned
        clearMenus()
    }

    func beginEditing(delegate: NSTextFieldDelegate) {
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.delegate = delegate
        DispatchQueue.main.async { [weak self] in
            guard let self, self.titleField.isEditable else { return }
            self.window?.makeFirstResponder(self.titleField)
            self.titleField.currentEditor()?.selectAll(nil)
        }
    }

    private func clearMenus() {
        menu = nil
        stack.menu = nil
        iconContainer.menu = nil
        symbolImageView.menu = nil
        titleField.menu = nil
        countField.menu = nil
        pinImageView.menu = nil
        badgeView?.menu = nil
    }

    private func setup() {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        symbolImageView.translatesAutoresizingMaskIntoConstraints = false
        symbolImageView.imageScaling = .scaleProportionallyDown
        iconContainer.addSubview(symbolImageView)
        iconCenterYConstraint = symbolImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor)

        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField = titleField

        countField.isBordered = false
        countField.drawsBackground = false
        countField.textColor = .secondaryLabelColor
        countField.alignment = .right
        countField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        countField.setContentHuggingPriority(.required, for: .horizontal)

        pinImageView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinImageView.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        pinImageView.contentTintColor = .secondaryLabelColor
        pinImageView.imageScaling = .scaleProportionallyDown
        pinImageView.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(iconContainer)
        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(countField)
        stack.addArrangedSubview(pinImageView)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 18),
            iconContainer.heightAnchor.constraint(equalToConstant: 18),
            symbolImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconCenterYConstraint,
            symbolImageView.widthAnchor.constraint(equalToConstant: 18),
            symbolImageView.heightAnchor.constraint(equalToConstant: 18),
            pinImageView.widthAnchor.constraint(equalToConstant: 12),
            pinImageView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    private func configureIcon(for node: SidebarOutlineNode) {
        badgeView?.removeFromSuperview()
        badgeView = nil
        symbolImageView.isHidden = false
        iconCenterYConstraint.constant = 0

        if let type = node.entryType {
            symbolImageView.isHidden = true
            let badge = NSHostingView(rootView: TypeBadge(type: type, size: 16).allowsHitTesting(false))
            badge.translatesAutoresizingMaskIntoConstraints = false
            iconContainer.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
                badge.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 18),
                badge.heightAnchor.constraint(equalToConstant: 18),
            ])
            badgeView = badge
        } else if let iconName = node.iconName {
            let isGroup: Bool
            if case .group = node.kind { isGroup = true } else { isGroup = false }
            symbolImageView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            symbolImageView.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            symbolImageView.contentTintColor = .labelColor
            iconCenterYConstraint.constant = isGroup ? 1.5 : 0
        } else {
            symbolImageView.image = nil
        }
    }

    private func isSection(_ node: SidebarOutlineNode) -> Bool {
        if case .section = node.kind { return true }
        return false
    }

    private func font(for node: SidebarOutlineNode) -> NSFont {
        isSection(node) ? .systemFont(ofSize: 11) : .systemFont(ofSize: NSFont.systemFontSize)
    }

    private func textColor(for node: SidebarOutlineNode) -> NSColor {
        isSection(node) ? .secondaryLabelColor : .labelColor
    }
}
