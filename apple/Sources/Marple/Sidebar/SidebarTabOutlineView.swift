import AppKit
import SwiftUI
import MarpleKit

private enum SidebarOutlineSection {
    case objects
    case views
    case tabs

    var title: String {
        switch self {
        case .objects: return "物件"
        case .views:   return "视图"
        case .tabs:    return "标签"
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
        case .tab(let id):   return "tab:\(id.uuidString)"
        case .group(let id): return "group:\(id.uuidString)"
        case .section, .pane: return nil
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

    init?(_ raw: String?) {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "tab":   self = .tab(id)
        case "group": self = .group(id)
        default:       return nil
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
        outline.allowsMultipleSelection = false
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
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
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        if let outline = scroll.documentView as? NSOutlineView {
            context.coordinator.scheduleReload(outline)
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let pasteboardType = NSPasteboard.PasteboardType("com.marple.sidebar-tab-item")

        var model: AppModel
        private var rootItems: [SidebarOutlineNode] = []
        private var isUpdatingSelection = false
        private var isRestoringExpansion = false
        private var pendingReload = false
        private var lastReloadSignature: String?
        private var stickyRowDropTarget: SidebarOutlineNode?
        private let rowDropEnterEdgeRatio: CGFloat = 0.36
        private let rowDropReleaseEdgeRatio: CGFloat = 0.36
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

        func reload(_ outline: NSOutlineView) {
            let signature = reloadSignature()
            guard signature != lastReloadSignature else {
                selectCurrentItem(in: outline)
                return
            }
            lastReloadSignature = signature
            stickyRowDropTarget = nil
            rootItems = makeRootItems()
            outline.reloadData()
            restoreExpansion(in: outline)
            selectCurrentItem(in: outline)
        }

        private func reloadSignature() -> String {
            var parts: [String] = []
            parts.append("entries:\(model.entries.count)")
            parts.append("browse:\(model.isBrowsing):\(model.pane)")
            parts.append("active:\(model.activeTabID?.uuidString ?? "nil")")
            parts.append("types:\(model.typeOrder.map(String.init(describing:)).joined(separator: ","))")
            parts.append("counts:\(model.typeOrder.map { "\($0)=\(model.counts[$0] ?? 0)" }.joined(separator: ","))")
            parts.append("views:\(model.themeIndex.count):\(model.trashItems.count)")
            parts.append("tabs:\(model.tabs.map { "\($0.id.uuidString):\($0.location):\($0.pinned)" }.joined(separator: ","))")
            parts.append("groups:\(model.tabGroups.map { "\($0.id.uuidString):\($0.name):\($0.isCollapsed):\($0.tabIDs.map(\.uuidString).joined(separator: "."))" }.joined(separator: ","))")
            return parts.joined(separator: "|")
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
                                   }),
                SidebarOutlineNode(kind: .section(.views), title: SidebarOutlineSection.views.title,
                                   children: [
                                       SidebarOutlineNode(kind: .pane(.themesIndex),
                                                          title: "主题",
                                                          count: model.themeIndex.count,
                                                          iconName: "tag"),
                                       SidebarOutlineNode(kind: .pane(.trash),
                                                          title: "回收站",
                                                          count: model.trashItems.count,
                                                          iconName: "trash")
                                   ])
            ]
            if !model.tabs.isEmpty {
                sections.append(SidebarOutlineNode(kind: .section(.tabs),
                                                   title: SidebarOutlineSection.tabs.title,
                                                   children: makeTabRootItems(entryByPath: entryByPath)))
            }
            return sections
        }

        private func makeTabRootItems(entryByPath: [String: Entry]) -> [SidebarOutlineNode] {
            var seenGroups: Set<TabGroup.ID> = []
            return model.tabs.compactMap { tab in
                if let group = model.tabGroup(containing: tab.id) {
                    guard seenGroups.insert(group.id).inserted else { return nil }
                    return SidebarOutlineNode(kind: .group(group.id),
                                              title: group.name,
                                              count: model.tabs(in: group.id).count,
                                              iconName: "rectangle.stack",
                                              children: model.tabs(in: group.id).map { tabNode($0, entryByPath: entryByPath) })
                }
                return tabNode(tab, entryByPath: entryByPath)
            }
        }

        private func tabNode(_ tab: NavTab, entryByPath: [String: Entry]) -> SidebarOutlineNode {
            let entry = tab.location.openPath.flatMap { entryByPath[$0] }
            return SidebarOutlineNode(kind: .tab(tab.id),
                                      title: tabTitle(tab, entry: entry),
                                      iconName: "list.bullet",
                                      pinned: tab.pinned,
                                      entryType: entry?.type)
        }

        private func tabTitle(_ tab: NavTab, entry: Entry?) -> String {
            let loc = tab.location
            if let path = loc.openPath {
                return entry?.title ?? (path as NSString).lastPathComponent
            }
            switch loc.pane {
            case .type(let type): return type.label
            case .theme(let name): return "#\(name)"
            case .themesIndex: return "主题"
            case .trash: return "回收站"
            }
        }

        private func restoreExpansion(in outline: NSOutlineView) {
            isRestoringExpansion = true
            defer { isRestoringExpansion = false }
            for section in rootItems {
                outline.expandItem(section)
            }
            for item in tabRootItems {
                if case .group(let id) = item.kind {
                    let collapsed = model.tabGroups.first { $0.id == id }?.isCollapsed ?? false
                    if collapsed {
                        outline.collapseItem(item)
                    } else {
                        outline.expandItem(item)
                    }
                }
            }
        }

        private var tabRootItems: [SidebarOutlineNode] {
            rootItems.first { $0.isTabsSection }?.children ?? []
        }

        private func selectCurrentItem(in outline: NSOutlineView) {
            let target: SidebarOutlineNode? = {
                if model.isBrowsing {
                    return findPaneNode(model.pane, in: rootItems)
                }
                guard let active = model.activeTabID else { return nil }
                if let group = model.tabGroup(containing: active), group.isCollapsed {
                    return findGroupNode(group.id, in: rootItems)
                }
                return findTabNode(active, in: rootItems)
            }()
            guard let target else {
                outline.deselectAll(nil)
                return
            }
            let row = outline.row(forItem: target)
            guard row >= 0 else { return }
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
            let view = NSHostingView(rootView: SidebarOutlineRow(node: node, model: model))
            view.identifier = NSUserInterfaceItemIdentifier("sidebar-row")
            return view
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection,
                  let outline = notification.object as? NSOutlineView else { return }
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

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let payload = SidebarTabPayload(info.draggingPasteboard.string(forType: Self.pasteboardType)) else { return [] }
            let point = draggingPoint(in: outlineView, info: info)
            logDrop("validate proposed=\(describe(item as? SidebarOutlineNode)) index=\(index) row=\(rowAtY(point.y, in: outlineView)) x=\(String(format: "%.1f", point.x)) y=\(String(format: "%.1f", point.y)) sticky=\(describe(stickyRowDropTarget)) payload=\(describe(payload))")
            if shouldRetargetToRow(outlineView, info: info, payload: payload) {
                logDrop("validate retarget sticky=\(describe(stickyRowDropTarget))")
                return .move
            }
            guard let node = item as? SidebarOutlineNode else { return [] }
            switch node.kind {
            case .section(.tabs):
                return .move
            case .group:
                if case .group = payload, index >= 0 { return [] }
                return .move
            case .tab:
                if index != NSOutlineViewDropOnItemIndex {
                    outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                }
                return .move
            case .section, .pane:
                return []
            }
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let payload = SidebarTabPayload(info.draggingPasteboard.string(forType: Self.pasteboardType)) else { return false }
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
                return true
            case (.group, .tab):
                return true
            default:
                return false
            }
        }

        private func draggingPoint(in outlineView: NSOutlineView, info: NSDraggingInfo) -> NSPoint {
            outlineView.convert(info.draggingLocation, from: nil)
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
            }
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
                model.moveGroup(groupID, beforeTab: tabRootItem(at: childIndex)?.firstTabID)
                return true
            }
            switch node.kind {
            case .tab(let targetID):
                model.moveGroup(groupID, beforeTab: targetID)
                return true
            case .group(let targetGroupID):
                guard childIndex < 0, groupID != targetGroupID else { return false }
                model.moveGroup(groupID, beforeGroup: targetGroupID)
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

private struct SidebarOutlineRow: View {
    let node: SidebarOutlineNode
    let model: AppModel

    var body: some View {
        switch node.kind {
        case .section:
            Text(node.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .pane, .tab, .group:
            Label {
                HStack {
                    Text(node.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if let count = node.count {
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if node.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                icon
            }
            .contextMenu { menu }
        }
    }

    @ViewBuilder private var icon: some View {
        if let type = node.entryType {
            TypeBadge(type: type, size: 16)
        } else if let iconName = node.iconName {
            Image(systemName: iconName)
                .frame(width: 18, height: 18, alignment: .center)
        }
    }

    @ViewBuilder private var menu: some View {
        switch node.kind {
        case .pane(let pane):
            if case .type(let type) = pane {
                typeContextMenu(for: type)
            }
        case .group(let id):
            if let group = model.tabGroups.first(where: { $0.id == id }) {
                Button(group.isCollapsed ? "展开标签组" : "折叠标签组") {
                    model.toggleTabGroup(id)
                }
            }
        case .tab(let id):
            if let tab = model.tabs.first(where: { $0.id == id }) {
                Button(tab.pinned ? "取消固定" : "固定标签") { model.togglePin(id) }
                Divider()
                Button("关闭标签") { Task { await model.closeTab(id) } }
                Button("关闭其他标签") { Task { await model.closeOtherTabs(id) } }
            }
        case .section:
            EmptyView()
        }
    }

    @ViewBuilder
    private func typeContextMenu(for type: EntryType) -> some View {
        let idx = model.typeOrder.firstIndex(of: type) ?? 0
        if idx > 0 {
            Button("上移") { moveType(type, by: -1) }
        }
        if idx < model.typeOrder.count - 1 {
            Button("下移") { moveType(type, by: 1) }
        }
        if idx > 0 || idx < model.typeOrder.count - 1 {
            Divider()
        }
        Button("重置顺序") { model.setTypeOrder(EntryType.modeled) }
    }

    private func moveType(_ type: EntryType, by delta: Int) {
        var order = model.typeOrder
        guard let idx = order.firstIndex(of: type) else { return }
        let target = idx + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(idx, target)
        model.setTypeOrder(order)
    }
}
