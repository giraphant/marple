import AppKit
import SwiftUI
import MarpleKit

// MARK: - Drag pasteboard

enum SidebarDragPasteboard {
    static let tabItem = NSPasteboard.PasteboardType("com.marple.sidebar-tab-item")
}

// MARK: - Outline model types

private enum SidebarOutlineSection {
    case objects
    case views
    case pinned
    case tabs

    var title: String {
        switch self {
        case .objects: return String(localized: "物件")
        case .views:   return String(localized: "视图")
        case .pinned:  return String(localized: "页面")
        case .tabs:    return String(localized: "页面")
        }
    }

    /// Stable key for persisting the section's collapsed state across
    /// reloads/launches (node objects are minted fresh every reload, so
    /// AppKit's own per-item expansion memory can't carry it).
    var key: String {
        switch self {
        case .objects: return "objects"
        case .views:   return "views"
        case .pinned:  return "pinned"
        case .tabs:    return "tabs"
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
    let sourceSpaceID: WorkspaceSpace.ID?
    var children: [SidebarOutlineNode]

    init(kind: Kind, title: String, count: Int? = nil, iconName: String? = nil,
         pinned: Bool = false, entryType: EntryType? = nil,
         sourceSpaceID: WorkspaceSpace.ID? = nil, children: [SidebarOutlineNode] = []) {
        self.kind = kind
        self.title = title
        self.count = count
        self.iconName = iconName
        self.pinned = pinned
        self.entryType = entryType
        self.sourceSpaceID = sourceSpaceID
        self.children = children
    }

    var payload: String? {
        switch kind {
        case .tab(let id):
            guard let sourceSpaceID else { return "tab:\(id.uuidString)" }
            return "tab:\(sourceSpaceID.uuidString):\(id.uuidString)"
        case .group(let id):
            guard let sourceSpaceID else { return "group:\(id.uuidString)" }
            return "group:\(sourceSpaceID.uuidString):\(id.uuidString)"
        case .pane(.type(let type)):
            return "type:\(type.rawValue)"
        case .pane(.savedView(let id)):
            return "savedview:\(id.uuidString)"
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

    var isPinnedSection: Bool {
        if case .section(.pinned) = kind { return true }
        return false
    }
}

private enum SidebarTabPayload {
    case tab(spaceID: WorkspaceSpace.ID?, id: NavTab.ID)
    case group(spaceID: WorkspaceSpace.ID?, id: TabGroup.ID)
    case type(EntryType)
    case savedView(UUID)
    /// A browse card dragged from the grid — "open this entry path as a tab".
    /// Lets a card drop flow through the exact same tab-drop machinery (insertion
    /// indicators, tab-on-tab grouping, Space dots) as a real tab. QUA-114.
    case entry(path: String)

    var sourceSpaceID: WorkspaceSpace.ID? {
        switch self {
        case .tab(let spaceID, _), .group(let spaceID, _): return spaceID
        case .type, .savedView, .entry: return nil
        }
    }

    /// Whether dropping this onto a tab should form a group (tab-on-tab gesture).
    var coercesOntoTab: Bool {
        switch self {
        case .tab, .entry: return true
        case .group, .type, .savedView: return false
        }
    }

    init?(_ raw: String?) {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "tab":
            if parts.count == 3 {
                guard let spaceID = UUID(uuidString: parts[1]), let id = UUID(uuidString: parts[2]) else { return nil }
                self = .tab(spaceID: spaceID, id: id)
            } else {
                guard let id = UUID(uuidString: parts[1]) else { return nil }
                self = .tab(spaceID: nil, id: id)
            }
        case "group":
            if parts.count == 3 {
                guard let spaceID = UUID(uuidString: parts[1]), let id = UUID(uuidString: parts[2]) else { return nil }
                self = .group(spaceID: spaceID, id: id)
            } else {
                guard let id = UUID(uuidString: parts[1]) else { return nil }
                self = .group(spaceID: nil, id: id)
            }
        case "type":
            self = .type(EntryType(rawValue: parts[1]))
        case "savedview":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .savedView(id)
        case "entry":
            // Path may itself contain ":" — rejoin everything after the prefix.
            self = .entry(path: parts[1...].joined(separator: ":"))
        default:
            return nil
        }
    }
}

// MARK: - SidebarOutlineView (NSViewRepresentable)

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
        outline.registerForDraggedTypes([SidebarDragPasteboard.tabItem])
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
        /// Collapsed sidebar sections by `SidebarOutlineSection.key`, persisted
        /// across launches. Lives here (not AppModel) — pure view chrome, the
        /// same way NSOutlineView owns its own scroll position.
        private var collapsedSections: Set<String> =
            Set(UserDefaults.standard.stringArray(forKey: "marple.collapsedSidebarSections") ?? [])
        private var lastReloadSpaceID: WorkspaceSpace.ID?
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

        // MARK: - Reload & model observation

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
                _ = model.hiddenTypes
                _ = model.counts
                _ = model.savedViews
                _ = model.savedViewCounts
                _ = model.tabs
                _ = model.tabRootNodes
                _ = model.spaces
                _ = model.activeSpaceID
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
            let spaceTransition = sidebarSpaceTransition(in: outline)
            lastReloadSignature = signature
            lastReloadSpaceID = model.activeSpaceID
            stickyRowDropTarget = nil
            rootItems = makeRootItems()
            if let spaceTransition, let clipView = outline.enclosingScrollView?.contentView {
                clipView.layer?.add(spaceTransition, forKey: "space-switch")
                outline.reloadData()
            } else {
                outline.reloadData()
            }
            restoreExpansion(in: outline)
            restoreMultiSelection(payloads: preservedPayloads, in: outline)
            selectCurrentItem(in: outline)
        }

        /// Payload set of a multi-row selection (>=2 rows). Returns empty for a
        /// single-row selection — `selectCurrentItem` will re-pick that case
        /// from the active tab/pane on its own.
        // MARK: - Selection preservation across reloads

        private func sidebarSpaceTransition(in outline: NSOutlineView) -> CATransition? {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  let oldID = lastReloadSpaceID,
                  let newID = model.activeSpaceID,
                  oldID != newID,
                  let oldIndex = model.spaces.firstIndex(where: { $0.id == oldID }),
                  let newIndex = model.spaces.firstIndex(where: { $0.id == newID }) else { return nil }
            outline.enclosingScrollView?.contentView.wantsLayer = true
            let transition = CATransition()
            transition.type = .push
            transition.subtype = newIndex > oldIndex ? .fromRight : .fromLeft
            transition.duration = 0.10
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            transition.isRemovedOnCompletion = true
            return transition
        }

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
            case .tab(_, let id): return findTabNode(id, in: nodes)
            case .group(_, let id): return findGroupNode(id, in: nodes)
            case .type(let type): return findPaneNode(.type(type), in: nodes)
            case .savedView(let id): return findPaneNode(.savedView(id), in: nodes)
            case .entry: return nil   // not an existing node
            }
        }

        // MARK: - Reload signature

        private func reloadSignature() -> String {
            var parts: [String] = []
            parts.append("entries:\(model.entries.count)")
            parts.append("browse:\(model.isBrowsing):\(model.pane)")
            // NOTE: activeTabID is deliberately NOT in the signature. The active
            // tab changes the row *selection* (driven by selectCurrentItem's
            // selectRowIndexes), never the row structure or cell content. Folding
            // it in here forced a full reloadData() on every tab click; because
            // makeRootItems() mints fresh node identities each pass, the outline
            // couldn't preserve expansion across that reload, which collapsed the
            // tree and clamped the scroll origin to the top — the viewport "jump".
            // An active-only change now hits the no-op-reload path (selection
            // update only), leaving the scroll position untouched.
            parts.append("types:\(model.visibleTypeOrder.map(String.init(describing:)).joined(separator: ","))")
            parts.append("counts:\(model.visibleTypeOrder.map { "\($0)=\(model.counts[$0] ?? 0)" }.joined(separator: ","))")
            parts.append("views:\(model.savedViews.map { "\($0.id.uuidString):\($0.name)=\(model.savedViewCounts[$0.id] ?? 0)" }.joined(separator: ","))")
            parts.append("tabs:\(model.tabs.map { "\($0.id.uuidString):\($0.identityLocation):\($0.pinned):\($0.customTitle ?? "")" }.joined(separator: ","))")
            parts.append("tree:\(Self.treeSignature(model.tabRootNodes))")
            parts.append("spaces:\(model.activeSpaceID?.uuidString ?? "nil"):\(model.spaces.map(\.id.uuidString).joined(separator: ","))")
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

        // MARK: - Node tree construction

        private func makeRootItems() -> [SidebarOutlineNode] {
            let entryByPath = Dictionary(model.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            var sections: [SidebarOutlineNode] = []
            // Hidden buckets (QUA-127) just drop out of the list; all hidden ⇒
            // the whole 物件 section disappears (re-enable via 设置 → 外观).
            let visibleTypes = model.visibleTypeOrder
            if !visibleTypes.isEmpty {
                sections.append(
                    SidebarOutlineNode(kind: .section(.objects), title: SidebarOutlineSection.objects.title,
                                       children: visibleTypes.map { type in
                                           SidebarOutlineNode(kind: .pane(.type(type)),
                                                              title: AppPresentation.entryTypeLabel(type),
                                                              count: model.counts[type] ?? 0,
                                                              iconName: type.symbolName)
                                       }))
            }
            // Saved smart-folder views (QUA-127). Section only exists once the
            // user has saved one — no empty「视图」header on a fresh install.
            if !model.savedViews.isEmpty {
                sections.append(
                    SidebarOutlineNode(kind: .section(.views), title: SidebarOutlineSection.views.title,
                                       children: model.savedViews.map { view in
                                           SidebarOutlineNode(kind: .pane(.savedView(view.id)),
                                                              title: view.name,
                                                              count: model.savedViewCounts[view.id] ?? 0,
                                                              iconName: "line.3.horizontal.decrease.circle")
                                       }))
            }
            sections.append(SidebarOutlineNode(kind: .section(.pinned),
                                               title: SidebarOutlineSection.pinned.title,
                                               children: makePinnedRootItems(entryByPath: entryByPath)))
            sections.append(SidebarOutlineNode(kind: .section(.tabs),
                                               title: SidebarOutlineSection.tabs.title,
                                               children: makeTemporaryItems(entryByPath: entryByPath)))
            return sections
        }

        private func makePinnedRootItems(entryByPath: [String: Entry]) -> [SidebarOutlineNode] {
            let sourceSpaceID = model.activeSpaceID
            return model.pinnedTabRootNodes.compactMap {
                outlineNode($0, entryByPath: entryByPath, sourceSpaceID: sourceSpaceID)
            }
        }

        private func makeTemporaryItems(entryByPath: [String: Entry]) -> [SidebarOutlineNode] {
            let sourceSpaceID = model.activeSpaceID
            return model.temporaryTabs.map {
                tabNode($0, entryByPath: entryByPath, sourceSpaceID: sourceSpaceID)
            }
        }

        private func outlineNode(_ node: TabNode, entryByPath: [String: Entry], sourceSpaceID: WorkspaceSpace.ID?) -> SidebarOutlineNode? {
            switch node {
            case .tab(let id):
                guard let tab = model.tabs.first(where: { $0.id == id }) else { return nil }
                return tabNode(tab, entryByPath: entryByPath, sourceSpaceID: sourceSpaceID)
            case .group(let group):
                return SidebarOutlineNode(kind: .group(group.id),
                                          title: group.name,
                                          count: nil,
                                          iconName: "folder",
                                          pinned: true,
                                          sourceSpaceID: sourceSpaceID,
                                          children: group.children.compactMap { outlineNode($0, entryByPath: entryByPath, sourceSpaceID: sourceSpaceID) })
            }
        }

        private func tabNode(_ tab: NavTab, entryByPath: [String: Entry], sourceSpaceID: WorkspaceSpace.ID?) -> SidebarOutlineNode {
            let location = tab.identityLocation
            let entry = location.openPath.flatMap { entryByPath[$0] }
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
                                      entryType: resolvedType,
                                      sourceSpaceID: sourceSpaceID)
        }

        private func tabTitle(_ tab: NavTab, entry: Entry?) -> String {
            if let customTitle = tab.customTitle { return customTitle }
            let loc = tab.identityLocation
            if let path = loc.openPath {
                if let live = entry?.title { return live }
                if let cached = tab.cachedTitle, !cached.isEmpty { return cached }
                return (path as NSString).lastPathComponent
            }
            switch loc.pane {
            case .type(let type): return AppPresentation.entryTypeLabel(type)
            case .theme(let name): return "#\(name)"
            case .themesIndex: return String(localized: "标签")
            case .trash: return String(localized: "回收站")
            case .savedView(let id): return model.savedView(id)?.name ?? String(localized: "视图")
            }
        }

        // MARK: - Expansion state

        private func restoreExpansion(in outline: NSOutlineView) {
            isRestoringExpansion = true
            defer { isRestoringExpansion = false }
            for section in rootItems {
                if case .section(let s) = section.kind, collapsedSections.contains(s.key) {
                    outline.collapseItem(section)
                } else {
                    outline.expandItem(section)
                }
            }
            // Group rows only exist while their section is expanded; a collapsed
            // 页面 section re-applies this lazily in outlineViewItemDidExpand.
            if !collapsedSections.contains(SidebarOutlineSection.pinned.key) {
                applyExpansion(to: pinnedRootItems, in: outline)
            }
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

        private var pinnedRootItems: [SidebarOutlineNode] {
            pinnedSection?.children ?? []
        }

        private var temporaryItems: [SidebarOutlineNode] {
            tabsSection?.children ?? []
        }

        private var showsPageDivider: Bool {
            !pinnedRootItems.isEmpty && !temporaryItems.isEmpty
        }

        private var tabsSection: SidebarOutlineNode? {
            rootItems.first { $0.isTabsSection }
        }

        private var pinnedSection: SidebarOutlineNode? {
            rootItems.first { $0.isPinnedSection }
        }

        private var objectsSection: SidebarOutlineNode? {
            rootItems.first {
                if case .section(.objects) = $0.kind { return true }
                return false
            }
        }

        private var viewsSection: SidebarOutlineNode? {
            rootItems.first {
                if case .section(.views) = $0.kind { return true }
                return false
            }
        }

        // MARK: - Current-item selection & node lookup

        private func selectCurrentItem(in outline: NSOutlineView) {
            let target: SidebarOutlineNode? = {
                if model.isBrowsing {
                    return findPaneNode(model.pane, in: rootItems)
                }
                guard let active = model.activeTabID else { return nil }
                if model.tabs.first(where: { $0.id == active })?.pinned == true,
                   let collapsed = model.outermostCollapsedTabGroup(of: active) {
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
                    scrollRowIntoViewIfOffscreen(row, in: outline)
                }
                return
            }
            isUpdatingSelection = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            scrollRowIntoViewIfOffscreen(row, in: outline)
            isUpdatingSelection = false
        }

        /// Only nudge the viewport when the target row is fully off-screen.
        /// A row that's still partially showing was either just clicked (the
        /// user can see it) or is close by — scrolling it flush is a surprise
        /// that costs the user their place when they're parked at the list's
        /// far end. Full-offscreen targets (search/keyboard nav to a distant
        /// tab) still scroll in. Mirrors the multi-selection restraint above.
        private func scrollRowIntoViewIfOffscreen(_ row: Int, in outline: NSOutlineView) {
            let rowRect = outline.rect(ofRow: row)
            guard !outline.visibleRect.intersects(rowRect) else { return }
            outline.scrollRowToVisible(row)
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

        // MARK: - NSOutlineView data source & delegate

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SidebarOutlineNode)?.children.count ?? rootItems.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? SidebarOutlineNode)?.children ?? rootItems)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? SidebarOutlineNode else { return false }
            return node.isPinnedSection || !node.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            guard let node = item as? SidebarOutlineNode else { return false }
            if node.isTabsSection { return false }
            if case .section = node.kind { return true }
            return false
        }

        func outlineView(_ outlineView: NSOutlineView,
                         shouldShowOutlineCellForItem item: Any) -> Bool {
            guard let node = item as? SidebarOutlineNode else { return true }
            return !node.isTabsSection
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? SidebarOutlineNode else { return false }
            if case .section = node.kind { return false }
            return true
        }

        // Sections collapse like Mail's mailbox groups (hover「隐藏」button);
        // state persists in collapsedSections so reloads don't pop them open.
        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            true
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? SidebarOutlineNode else { return 30 }
            switch node.kind {
            case .section(.tabs):
                return showsPageDivider
                    ? SidebarPageDividerCellView.height
                    : CGFloat.leastNormalMagnitude
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
            if node.isTabsSection {
                guard showsPageDivider else { return nil }
                let view = outlineView.makeView(
                    withIdentifier: SidebarPageDividerCellView.identifier,
                    owner: self) as? SidebarPageDividerCellView ?? SidebarPageDividerCellView()
                return view
            }
            let view = outlineView.makeView(withIdentifier: SidebarOutlineCellView.identifier, owner: self) as? SidebarOutlineCellView
                ?? SidebarOutlineCellView()
            view.configure(node: node, coordinator: self)
            return view
        }

        // MARK: - Rename

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
            case .pane(let pane): return findPaneNode(pane, in: rootItems)
            case .section: return node
            }
        }

        private func canRename(_ node: SidebarOutlineNode) -> Bool {
            switch node.kind {
            case .tab, .group: return true
            case .pane(.savedView): return true   // user-named smart folder (QUA-127)
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
            case .pane(.savedView(let id)):
                model.renameSavedView(id, to: value)   // no-op on empty/whitespace
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

        // MARK: - Context menu

        func menuNeedsUpdate(_ contextMenu: NSMenu) {
            contextMenu.removeAllItems()
            guard let outline = outlineView else { return }
            // Right-click on a section header (non-selectable) shouldn't pop a
            // menu over the current selection, which sits elsewhere.
            let clicked = outline.clickedRow
            if clicked >= 0, let clickedNode = outline.item(atRow: clicked) as? SidebarOutlineNode,
               case .section = clickedNode.kind { return }
            // Type buckets get a single display action (QUA-127); re-show lives
            // in 设置 → 外观 → 侧栏物件.
            if clicked >= 0, let clickedNode = outline.item(atRow: clicked) as? SidebarOutlineNode,
               case .pane(.type) = clickedNode.kind {
                contextMenu.addItem(menuItem(String(localized: "在侧栏中隐藏"), action: #selector(hideTypeFromMenu(_:)), node: clickedNode))
                return
            }
            // Saved views: rename in place, delete for good (QUA-127). Deleting
            // is just dropping a stored filter — no confirmation dance.
            if clicked >= 0, let clickedNode = outline.item(atRow: clicked) as? SidebarOutlineNode,
               case .pane(.savedView) = clickedNode.kind {
                contextMenu.addItem(menuItem(String(localized: "重命名"), action: #selector(renameFromMenu(_:)), node: clickedNode))
                contextMenu.addItem(.separator())
                contextMenu.addItem(menuItem(String(localized: "删除视图"), action: #selector(deleteSavedViewFromMenu(_:)), node: clickedNode))
                return
            }
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

            let closeItem = NSMenuItem(title: String(localized: "关闭这 \(n) 个"), action: #selector(closeBatchFromMenu(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.representedObject = Array(tabIDs) as NSArray
            // Pin-only selection has no actionable closes; reflect that visually.
            let pinned = Set(model.tabs.filter(\.pinned).map(\.id))
            closeItem.isEnabled = !tabIDs.allSatisfy { pinned.contains($0) }
            items.append(closeItem)

            if allTabs {
                let groupItem = NSMenuItem(title: String(localized: "把这 \(n) 个合成一个新组"),
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
                var items = [menuItem(String(localized: "重命名"), action: #selector(renameFromMenu(_:)), node: node)]
                if let group = model.tabGroups.first(where: { $0.id == id }) {
                    items.append(menuItem(group.isCollapsed
                        ? String(localized: "展开页面组")
                        : String(localized: "折叠页面组"),
                        action: #selector(toggleGroupFromMenu(_:)), node: node))
                }
                items.append(.separator())
                items.append(menuItem(String(localized: "复制分享清单"), action: #selector(copyShareManifestFromMenu(_:)), node: node))
                return items
            case .tab(let id):
                guard let tab = model.tabs.first(where: { $0.id == id }) else { return [] }
                var items = [menuItem(String(localized: "重命名"), action: #selector(renameFromMenu(_:)), node: node)]
                items.append(.separator())
                items.append(menuItem(String(localized: "复制分享清单"), action: #selector(copyShareManifestFromMenu(_:)), node: node))
                items.append(.separator())
                items.append(menuItem(tab.pinned
                    ? String(localized: "取消固定")
                    : String(localized: "固定页面"),
                    action: #selector(togglePinFromMenu(_:)), node: node))
                items.append(.separator())
                let closeItem = menuItem(String(localized: "关闭页面"), action: #selector(closeTabFromMenu(_:)), node: node)
                closeItem.isEnabled = tab.pinned || model.tabs.count > 1
                items.append(closeItem)
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

        @objc private func hideTypeFromMenu(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarOutlineNode,
                  case .pane(.type(let type)) = node.kind else { return }
            model.setTypeHidden(type, hidden: true)
        }

        @objc private func deleteSavedViewFromMenu(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarOutlineNode,
                  case .pane(.savedView(let id)) = node.kind else { return }
            model.deleteSavedView(id)
        }

        @objc private func copyShareManifestFromMenu(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarOutlineNode else { return }
            let markdown: String?
            switch node.kind {
            case .tab(let id):   markdown = model.shareManifest(forTab: id)
            case .group(let id): markdown = model.shareManifest(forGroup: id)
            default:             markdown = nil
            }
            guard let markdown else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            model.flash(String(localized: "已复制分享清单"))
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

        // MARK: - Selection & expansion notifications

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
                // Keep the group row selected; do NOT re-route to its first
                // child. The highlight is derived from `activeTabID` in
                // `selectCurrentItem`, and a group has no tab identity — so
                // activating a child here bounces the highlight straight off
                // the group onto that child, making groups impossible to land
                // on by arrow key or to target by right-click rename.
                break
            case .section:
                break
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isRestoringExpansion,
                  let node = notification.userInfo?["NSObject"] as? SidebarOutlineNode else { return }
            switch node.kind {
            case .group(let id):
                model.setTabGroup(id, collapsed: false)
            case .section(let s):
                collapsedSections.remove(s.key)
                saveCollapsedSections()
                // Fresh-minted child rows materialize collapsed; restore the
                // persisted group expansion the deferred restoreExpansion skipped.
                if case .pinned = s, let outline = notification.object as? NSOutlineView {
                    isRestoringExpansion = true
                    applyExpansion(to: node.children, in: outline)
                    isRestoringExpansion = false
                }
            case .tab, .pane:
                break
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isRestoringExpansion,
                  let node = notification.userInfo?["NSObject"] as? SidebarOutlineNode else { return }
            switch node.kind {
            case .group(let id):
                model.setTabGroup(id, collapsed: true)
            case .section(let s):
                collapsedSections.insert(s.key)
                saveCollapsedSections()
            case .tab, .pane:
                break
            }
        }

        private func saveCollapsedSections() {
            UserDefaults.standard.set(Array(collapsedSections).sorted(),
                                      forKey: "marple.collapsedSidebarSections")
        }

        // MARK: - Drag & drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarOutlineNode, let payload = node.payload else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(payload, forType: SidebarDragPasteboard.tabItem)
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
                item.string(forType: SidebarDragPasteboard.tabItem).flatMap(SidebarTabPayload.init)
            }
        }

        private func sourceSpaceID(for payload: SidebarTabPayload) -> WorkspaceSpace.ID? {
            payload.sourceSpaceID ?? model.activeSpaceID
        }

        private func singleSourceSpaceID(for payloads: [SidebarTabPayload]) -> WorkspaceSpace.ID? {
            var source: WorkspaceSpace.ID?
            for payload in payloads {
                switch payload {
                case .type, .savedView:
                    continue   // pane reorders carry no Space identity
                default:
                    let spaceID = sourceSpaceID(for: payload)
                    if source == nil { source = spaceID }
                    else if source != spaceID { return nil }
                }
            }
            return source
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let allPayloads = payloads(from: info)
            if !allPayloads.isEmpty, allPayloads.allSatisfy(canMoveToTemporary),
               retargetTemporaryRowDrop(outlineView, info: info, item: item) {
                return .move
            }
            if allPayloads.count > 1 {
                return validateMultiDrop(outlineView, info: info, payloads: allPayloads,
                                         item: item, childIndex: index)
            }
            guard let payload = allPayloads.first
                    ?? SidebarTabPayload(info.draggingPasteboard.string(forType: SidebarDragPasteboard.tabItem)) else { return [] }
            let point = draggingPoint(in: outlineView, info: info)
            logDrop("validate proposed=\(describe(item as? SidebarOutlineNode)) index=\(index) row=\(rowAtY(point.y, in: outlineView)) x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y)) sticky=\(describe(stickyRowDropTarget)) payload=\(describe(payload))")
            if case .type = payload {
                return validateTypeDrop(outlineView, info: info, item: item, childIndex: index)
            }
            if case .savedView = payload {
                return validateSavedViewDrop(outlineView, info: info, item: item, childIndex: index)
            }
            if shouldRetargetToRow(outlineView, info: info, payload: payload) {
                logDrop("validate retarget sticky=\(describe(stickyRowDropTarget))")
                return .move
            }
            if item == nil, let section = tabsSection, point.y >= outlineView.rect(ofRow: outlineView.row(forItem: section)).minY {
                guard canMoveToTemporary(payload) else { return [] }
                outlineView.setDropItem(section, dropChildIndex: temporaryItems.count)
                return .move
            }
            guard let node = item as? SidebarOutlineNode else { return [] }
            switch node.kind {
            case .section(.tabs):
                return canMoveToTemporary(payload) ? .move : []
            case .section(.pinned):
                return .move
            case .group(let targetGroupID):
                // drop-on (center) nests; drop-between reorders/nests at an index.
                // Reject group payloads that would form a cycle (self / descendant).
                if case .group(_, let sourceID) = payload, sourceSpaceID(for: payload) == model.activeSpaceID {
                    return model.canNestGroup(sourceID, into: targetGroupID) ? .move : []
                }
                return .move
            case .tab(let targetID):
                if !node.pinned { return canMoveToTemporary(payload) ? .move : [] }
                if case .group(_, let sourceID) = payload, sourceSpaceID(for: payload) == model.activeSpaceID, model.groupContainsTab(sourceID, targetID) { return [] }
                // Coerce to drop-on only for tab payloads (the tab-on-tab grouping
                // gesture). Group payloads keep AppKit's between proposal so an edge
                // drop reorders beside the tab instead of grouping onto it.
                if payload.coercesOntoTab, index != NSOutlineViewDropOnItemIndex {
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
                    ?? SidebarTabPayload(info.draggingPasteboard.string(forType: SidebarDragPasteboard.tabItem)) else { return false }
            if case .type(let type) = payload {
                let accepted = acceptType(type, into: item as? SidebarOutlineNode, childIndex: index,
                                          outlineView: outlineView, info: info)
                if accepted { reload(outlineView) }
                return accepted
            }
            if case .savedView(let id) = payload {
                let accepted = acceptSavedView(id, into: item as? SidebarOutlineNode, childIndex: index,
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
                case .section(.pinned), .section(.tabs):
                    accepted = accept(payload, into: node, childIndex: index)
                case .tab, .group:
                    accepted = accept(payload, into: node, childIndex: index)
                case .section, .pane:
                    accepted = false
                }
            } else if let section = tabsSection, point.y >= outlineView.rect(ofRow: outlineView.row(forItem: section)).minY {
                accepted = accept(payload, into: section, childIndex: temporaryItems.count)
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
        // MARK: Drag & drop — multi-selection drops

        private func classifyAndFilter(_ payloads: [SidebarTabPayload]) -> (tabs: [NavTab.ID], groups: [TabGroup.ID]) {
            var rawTabs: [NavTab.ID] = []
            var rawGroups: [TabGroup.ID] = []
            for p in payloads {
                switch p {
                case .tab(_, let id): rawTabs.append(id)
                case .group(_, let id): rawGroups.append(id)
                case .type, .savedView, .entry: break   // not part of batch tab/group DnD
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
                case .tab(_, let id): return allowedTabs.contains(id) ? .tab(id) : nil
                case .group(_, let id): return allowedGroups.contains(id) ? .group(id) : nil
                case .type, .savedView, .entry: return nil
                }
            }
        }

        /// Paths if every payload is a browse-card entry (a multi-card drag), else nil.
        private func allEntryPaths(_ payloads: [SidebarTabPayload]) -> [String]? {
            var paths: [String] = []
            for p in payloads {
                guard case .entry(let path) = p else { return nil }
                paths.append(path)
            }
            return paths.isEmpty ? nil : paths
        }

        /// Open a batch of dragged cards as tabs, preserving selection order, then
        /// position them like a multi-tab drop (root index / into group / grouped
        /// onto a tab). Mirrors `acceptMultiDrop`'s tab handling. QUA-114.
        private func acceptEntryBatch(_ paths: [String], into node: SidebarOutlineNode?, childIndex: Int) -> Bool {
            let beforePinnedID = pinnedRootItem(at: childIndex)?.firstTabID
            let beforeTemporaryID = temporaryAnchor(at: childIndex)
            let kind = node?.kind
            Task { @MainActor in
                var newIDs: [NavTab.ID] = []
                for path in paths {
                    if let id = await model.openEntryTab(path) { newIDs.append(id) }
                }
                guard !newIDs.isEmpty else { return }
                switch kind {
                case .tab(let targetID)?:
                    model.setPinned(newIDs, to: true)
                    model.groupTabs([targetID] + newIDs)
                case .group(let groupID)?:
                    model.setPinned(newIDs, to: true)
                    var at = childIndex >= 0 ? childIndex : nil
                    for id in newIDs {
                        model.moveTab(id, toGroup: groupID, at: at)
                        if at != nil { at! += 1 }
                    }
                case .section(.pinned)?:
                    model.setPinned(newIDs, to: true)
                    for id in newIDs { model.moveTabToRoot(id, beforeTab: beforePinnedID) }
                case .section(.tabs)?:
                    for id in newIDs { model.moveTabToRoot(id, beforeTab: beforeTemporaryID) }
                default:
                    for id in newIDs { model.moveTabToRoot(id, beforeTab: nil) }
                }
            }
            return true
        }

        private func validateMultiDrop(_ outlineView: NSOutlineView, info: NSDraggingInfo,
                                       payloads: [SidebarTabPayload],
                                       item: Any?, childIndex index: Int) -> NSDragOperation {
            if allEntryPaths(payloads) != nil {
                guard let node = item as? SidebarOutlineNode else { return .move }
                switch node.kind {
                case .section(.pinned), .section(.tabs), .group: return .move
                case .tab:
                    guard node.pinned else { return [] }
                    if index != NSOutlineViewDropOnItemIndex {
                        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                    }
                    return .move
                case .section, .pane: return []
                }
            }
            guard let sourceSpaceID = singleSourceSpaceID(for: payloads) else { return [] }
            let crossSpace = sourceSpaceID != model.activeSpaceID
            let (tabs, groups) = classifyAndFilter(payloads)
            guard !(tabs.isEmpty && groups.isEmpty) else { return [] }
            // Drop on the root tabs section or between rows.
            guard let node = item as? SidebarOutlineNode else { return groups.isEmpty ? .move : [] }
            switch node.kind {
            case .section(.tabs):
                return groups.isEmpty ? .move : []
            case .section(.pinned):
                return .move
            case .group(let targetGroupID):
                // Reject the whole batch if any group payload would cycle.
                if !crossSpace, groups.contains(where: { !model.canNestGroup($0, into: targetGroupID) }) { return [] }
                // Reject if any tab payload is already a descendant of target via
                // a *different* group also in selection — but ancestor filter
                // already pruned that case. So allow.
                return .move
            case .tab(let targetID):
                guard node.pinned else { return [] }
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
            if let paths = allEntryPaths(payloads) {
                let accepted = acceptEntryBatch(paths, into: item as? SidebarOutlineNode, childIndex: index)
                stickyRowDropTarget = nil
                return accepted
            }
            guard let sourceSpaceID = singleSourceSpaceID(for: payloads) else { return false }
            let crossSpace = sourceSpaceID != model.activeSpaceID
            let items = orderedItems(payloads)
            guard !items.isEmpty else { return false }
            logDrop("acceptMulti items=\(items.count) target=\(describe(item as? SidebarOutlineNode)) index=\(index)")
            let tabIDs = items.compactMap { item -> NavTab.ID? in
                if case .tab(let id) = item { return id }
                return nil
            }
            let node = item as? SidebarOutlineNode ?? tabsSection
            guard let node else { return false }
            switch node.kind {
            case .group(let targetGroupID):
                if crossSpace {
                    model.moveItems(items, from: sourceSpaceID, toGroup: targetGroupID, at: index >= 0 ? index : nil)
                    model.setPinned(tabIDs, to: true)
                } else {
                    model.setPinned(tabIDs, to: true)
                    model.moveItems(items, toGroup: targetGroupID, at: index >= 0 ? index : nil)
                }
                return true
            case .tab(let targetID):
                // Pure-tab onto-tab forms a new group of [target, ...dragged].
                // `groupTabs` already DFS-orders, so source visual order is
                // re-resolved to tree position — that's the correct policy for
                // creating a fresh group rather than a flat sequence.
                guard node.pinned, !crossSpace, tabIDs.count == items.count else { return false }
                model.setPinned(tabIDs, to: true)
                let combined = [targetID] + tabIDs.filter { $0 != targetID }
                model.groupTabs(combined)
                return true
            case .section(.pinned):
                let safeIndex = index >= 0 ? index : nil
                if crossSpace {
                    model.moveItems(items, from: sourceSpaceID, toRootAt: safeIndex)
                    model.setPinned(tabIDs, to: true)
                } else {
                    model.setPinned(tabIDs, to: true)
                    model.moveItemsToRoot(items, at: safeIndex)
                }
                return true
            case .section(.tabs):
                guard tabIDs.count == items.count else { return false }
                let beforeID = temporaryAnchor(at: index, moving: Set(tabIDs))
                if crossSpace {
                    model.moveItems(items, from: sourceSpaceID, toRootAt: nil)
                }
                model.setPinned(tabIDs, to: false)
                for id in tabIDs { model.moveTabToRoot(id, beforeTab: beforeID) }
                return true
            case .section, .pane:
                return false
            }
        }

        // MARK: Drag & drop — type & saved-view reorder

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
               // Drop indicator slots are positions among the VISIBLE children,
               // so index against visibleTypeOrder, not the full order (QUA-127).
               let targetIndex = model.visibleTypeOrder.firstIndex(of: targetType) {
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

        /// Saved-view reorder within the 视图 section (QUA-210) — same shape as
        /// `validateTypeDrop`, minus the hidden-bucket indirection: every saved
        /// view is always visible, so the drop slot indexes `savedViews` directly.
        private func validateSavedViewDrop(_ outlineView: NSOutlineView, info: NSDraggingInfo,
                                           item: Any?, childIndex index: Int) -> NSDragOperation {
            if let node = item as? SidebarOutlineNode,
               case .section(.views) = node.kind,
               index >= 0 {
                return .move
            }
            let point = draggingPoint(in: outlineView, info: info)
            let row = rowAtY(point.y, in: outlineView)
            guard row >= 0,
                  let node = outlineView.item(atRow: row) as? SidebarOutlineNode,
                  let views = viewsSection else { return [] }
            if case .pane(.savedView(let targetID)) = node.kind,
               let targetIndex = model.savedViews.firstIndex(where: { $0.id == targetID }) {
                let rect = outlineView.rect(ofRow: row)
                let childIndex = point.y < rect.midY ? targetIndex : targetIndex + 1
                outlineView.setDropItem(views, dropChildIndex: childIndex)
                return .move
            }
            if case .section(.views) = node.kind {
                outlineView.setDropItem(views, dropChildIndex: 0)
                return .move
            }
            return []
        }

        // MARK: Drag & drop — row targeting & hit-testing

        private func canMoveToTemporary(_ payload: SidebarTabPayload) -> Bool {
            switch payload {
            case .tab, .entry: return true
            case .group, .type, .savedView: return false
            }
        }

        private func retargetTemporaryRowDrop(_ outlineView: NSOutlineView,
                                              info: NSDraggingInfo,
                                              item: Any?) -> Bool {
            guard let node = item as? SidebarOutlineNode,
                  case .tab(let targetID) = node.kind,
                  !node.pinned,
                  let section = tabsSection,
                  let targetIndex = temporaryItems.firstIndex(where: {
                      if case .tab(let id) = $0.kind { return id == targetID }
                      return false
                  }),
                  let row = rowForItem(node, in: outlineView) else { return false }
            let point = draggingPoint(in: outlineView, info: info)
            let slot = point.y < outlineView.rect(ofRow: row).midY
                ? targetIndex : targetIndex + 1
            stickyRowDropTarget = nil
            outlineView.setDropItem(section, dropChildIndex: slot)
            return true
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
            if case .tab = node.kind, !node.pinned { return false }
            let crossSpace = sourceSpaceID(for: payload) != model.activeSpaceID
            switch (payload, node.kind) {
            case (.tab(_, let sourceID), .tab(let targetID)) where !crossSpace && sourceID != targetID:
                return true
            case (.tab, .group):
                return true
            case (.group, .group) where crossSpace:
                return true
            case (.group(_, let sourceID), .group(let targetID)) where sourceID != targetID:
                return model.canNestGroup(sourceID, into: targetID)
            case (.group(_, let sourceID), .tab(let targetID)) where !crossSpace:
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
            case .tab(_, let id): return "tab(\(id.uuidString.prefix(6)))"
            case .group(_, let id): return "group(\(id.uuidString.prefix(6)))"
            case .type(let type): return "type(\(type.rawValue))"
            case .savedView(let id): return "savedview(\(id.uuidString.prefix(6)))"
            case .entry(let path): return "entry(\((path as NSString).lastPathComponent))"
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

        // MARK: Drag & drop — accept handlers

        private func accept(_ payload: SidebarTabPayload, into node: SidebarOutlineNode?, childIndex: Int) -> Bool {
            let sourceSpaceID = sourceSpaceID(for: payload)
            switch payload {
            case .tab(_, let sourceID):
                return acceptTab(sourceID, sourceSpaceID: sourceSpaceID, into: node, childIndex: childIndex)
            case .group(_, let groupID):
                return acceptGroup(groupID, sourceSpaceID: sourceSpaceID, into: node, childIndex: childIndex)
            case .type(let type):
                return acceptType(type, into: node, childIndex: childIndex)
            case .savedView(let id):
                return acceptSavedView(id, into: node, childIndex: childIndex)
            case .entry(let path):
                return acceptEntry(path, into: node, childIndex: childIndex)
            }
        }

        /// Open a browse-card entry as a tab in the active space, then position the
        /// new tab exactly like a dropped tab would land (root index / into a group /
        /// grouped onto a tab). Mirrors `acceptTab`.
        private func acceptEntry(_ path: String, into node: SidebarOutlineNode?, childIndex: Int) -> Bool {
            let beforePinnedID = pinnedRootItem(at: childIndex)?.firstTabID
            let beforeTemporaryID = temporaryAnchor(at: childIndex)
            let kind = node?.kind
            Task { @MainActor in
                guard let newID = await model.openEntryTab(path) else { return }
                switch kind {
                case .tab(let targetID)?:
                    model.setPinned([newID], to: true)
                    model.groupTab(newID, onto: targetID)
                case .group(let groupID)?:
                    model.setPinned([newID], to: true)
                    model.moveTab(newID, toGroup: groupID, at: childIndex >= 0 ? childIndex : nil)
                case .section(.pinned)?:
                    model.setPinned([newID], to: true)
                    model.moveTabToRoot(newID, beforeTab: beforePinnedID)
                case .section(.tabs)?:
                    model.moveTabToRoot(newID, beforeTab: beforeTemporaryID)
                default:
                    model.moveTabToRoot(newID, beforeTab: nil)
                }
            }
            return true
        }

        private func acceptType(_ type: EntryType, into node: SidebarOutlineNode?, childIndex: Int,
                                outlineView: NSOutlineView? = nil, info: NSDraggingInfo? = nil) -> Bool {
            // All indices here are positions among the VISIBLE rows (that's what
            // AppKit hands us); the reorder is applied to the full typeOrder by
            // anchoring on the visible neighbour, so hidden buckets keep their
            // relative place (QUA-127).
            let visible = model.visibleTypeOrder
            let targetIndex: Int? = {
                guard let node else { return nil }
                if case .section(.objects) = node.kind, childIndex >= 0 {
                    return childIndex
                }
                guard let outlineView, let info,
                      case .pane(.type(let targetType)) = node.kind,
                      let row = rowForItem(node, in: outlineView),
                      let index = visible.firstIndex(of: targetType) else { return nil }
                let point = draggingPoint(in: outlineView, info: info)
                return point.y < outlineView.rect(ofRow: row).midY ? index : index + 1
            }()
            guard let targetIndex,
                  let from = visible.firstIndex(of: type) else { return false }
            let remaining = visible.filter { $0 != type }
            let dropAt = min(max(from < targetIndex ? targetIndex - 1 : targetIndex, 0), remaining.count)
            var order = model.typeOrder
            order.removeAll { $0 == type }
            let fullIndex = dropAt < remaining.count
                ? (order.firstIndex(of: remaining[dropAt]) ?? order.count)
                : order.count
            order.insert(type, at: fullIndex)
            model.setTypeOrder(order)
            return true
        }

        /// Resolve the drop to a slot among the saved views and let the model
        /// reorder. Mirrors `acceptType`'s slot math, without the visible/full
        /// split (no hidden saved views). QUA-210.
        private func acceptSavedView(_ id: UUID, into node: SidebarOutlineNode?, childIndex: Int,
                                     outlineView: NSOutlineView? = nil, info: NSDraggingInfo? = nil) -> Bool {
            let targetIndex: Int? = {
                guard let node else { return nil }
                if case .section(.views) = node.kind, childIndex >= 0 {
                    return childIndex
                }
                guard let outlineView, let info,
                      case .pane(.savedView(let targetID)) = node.kind,
                      let row = rowForItem(node, in: outlineView),
                      let index = model.savedViews.firstIndex(where: { $0.id == targetID }) else { return nil }
                let point = draggingPoint(in: outlineView, info: info)
                return point.y < outlineView.rect(ofRow: row).midY ? index : index + 1
            }()
            guard let targetIndex else { return false }
            return model.moveSavedView(id, to: targetIndex)
        }

        private func acceptTab(_ sourceID: NavTab.ID, sourceSpaceID: WorkspaceSpace.ID?, into node: SidebarOutlineNode?, childIndex: Int) -> Bool {
            let crossSpace = sourceSpaceID != model.activeSpaceID
            if !crossSpace, !model.tabs.contains(where: { $0.id == sourceID }) { return false }
            guard let node else {
                if let sourceSpaceID, crossSpace {
                    model.moveItems([.tab(sourceID)], from: sourceSpaceID, toRootAt: childIndex >= 0 ? childIndex : nil)
                } else {
                    model.moveTabToRoot(sourceID, beforeTab: pinnedRootItem(at: childIndex)?.firstTabID)
                }
                return true
            }
            switch node.kind {
            case .tab(let targetID):
                guard node.pinned, !crossSpace, sourceID != targetID else { return false }
                model.setPinned([sourceID], to: true)
                model.groupTab(sourceID, onto: targetID)
                return true
            case .group(let groupID):
                if let sourceSpaceID, crossSpace {
                    model.moveItems([.tab(sourceID)], from: sourceSpaceID, toGroup: groupID, at: childIndex >= 0 ? childIndex : nil)
                    model.setPinned([sourceID], to: true)
                } else {
                    model.setPinned([sourceID], to: true)
                    model.moveTab(sourceID, toGroup: groupID, at: childIndex >= 0 ? childIndex : nil)
                }
                return true
            case .section(.pinned):
                let beforeID = pinnedRootItem(at: childIndex)?.firstTabID
                if let sourceSpaceID, crossSpace {
                    model.moveItems([.tab(sourceID)], from: sourceSpaceID,
                                    toRootAt: childIndex >= 0 ? childIndex : nil)
                    model.setPinned([sourceID], to: true)
                } else {
                    model.setPinned([sourceID], to: true)
                    model.moveTabToRoot(sourceID, beforeTab: beforeID)
                }
                return true
            case .section(.tabs):
                let beforeID = temporaryAnchor(at: childIndex, moving: [sourceID])
                if let sourceSpaceID, crossSpace {
                    model.moveItems([.tab(sourceID)], from: sourceSpaceID, toRootAt: nil)
                }
                model.setPinned([sourceID], to: false)
                model.moveTabToRoot(sourceID, beforeTab: beforeID)
                return true
            case .section, .pane:
                return false
            }
        }

        private func acceptGroup(_ groupID: TabGroup.ID, sourceSpaceID: WorkspaceSpace.ID?, into node: SidebarOutlineNode?, childIndex: Int) -> Bool {
            let crossSpace = sourceSpaceID != model.activeSpaceID
            if !crossSpace, !model.tabGroups.contains(where: { $0.id == groupID }) { return false }
            guard let node else {
                // Root-section drop between rows: place at root by index (never nest).
                if let sourceSpaceID, crossSpace {
                    model.moveItems([.group(groupID)], from: sourceSpaceID, toRootAt: childIndex >= 0 ? childIndex : nil)
                } else {
                    model.moveGroupToRoot(groupID, at: childIndex >= 0 ? childIndex : nil)
                }
                return true
            }
            switch node.kind {
            case .tab(let targetID):
                guard !crossSpace, !model.groupContainsTab(groupID, targetID) else { return false }
                model.moveGroup(groupID, beforeTab: targetID)
                return true
            case .group(let targetGroupID):
                if let sourceSpaceID, crossSpace {
                    model.moveItems([.group(groupID)], from: sourceSpaceID, toGroup: targetGroupID, at: childIndex >= 0 ? childIndex : nil)
                } else {
                    guard groupID != targetGroupID, model.canNestGroup(groupID, into: targetGroupID) else { return false }
                    if childIndex < 0 {
                        model.moveGroup(groupID, intoGroup: targetGroupID)   // drop-on: nest at end
                    } else {
                        model.moveGroup(groupID, intoGroup: targetGroupID, at: childIndex)
                    }
                }
                return true
            case .section(.pinned):
                if let sourceSpaceID, crossSpace {
                    model.moveItems([.group(groupID)], from: sourceSpaceID,
                                    toRootAt: childIndex >= 0 ? childIndex : nil)
                } else {
                    model.moveGroupToRoot(groupID, at: childIndex >= 0 ? childIndex : nil)
                }
                return true
            case .section, .pane:
                return false
            }
        }

        private func pinnedRootItem(at index: Int) -> SidebarOutlineNode? {
            guard pinnedRootItems.indices.contains(index) else { return nil }
            return pinnedRootItems[index]
        }

        private func temporaryAnchor(at index: Int, moving: Set<NavTab.ID> = []) -> NavTab.ID? {
            let target = index >= 0 ? index : temporaryItems.count
            let ids = temporaryItems.compactMap { node -> NavTab.ID? in
                guard case .tab(let id) = node.kind, !moving.contains(id) else { return nil }
                return id
            }
            let removedBefore = temporaryItems.prefix(target).reduce(into: 0) { count, node in
                if case .tab(let id) = node.kind, moving.contains(id) { count += 1 }
            }
            let adjusted = max(target - removedBefore, 0)
            return ids.indices.contains(adjusted) ? ids[adjusted] : nil
        }
    }
}

// MARK: - Cell view

@MainActor
private final class SidebarPageDividerCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-page-divider-cell")
    static let height: CGFloat = 13

    private let divider = NSBox()

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

    private func setup() {
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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

        stack.addArrangedSubview(iconContainer)
        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(countField)

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
