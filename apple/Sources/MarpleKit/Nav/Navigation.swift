import Foundation

/// A restorable place in the app: which list/themes pane is shown plus which doc
/// (if any) is open. Both columns restore together when a tab/history entry is
/// activated.
public struct NavLocation: Hashable, Sendable, Codable {
    public var pane: Pane
    public var openPath: String?
    public init(pane: Pane, openPath: String? = nil) {
        self.pane = pane
        self.openPath = openPath
    }
}

/// A browser-style back/forward stack of locations. A new push past the current
/// index truncates the forward entries.
public struct NavHistory: Hashable, Sendable {
    public private(set) var entries: [NavLocation]
    public private(set) var index: Int

    public init(_ initial: NavLocation) {
        entries = [initial]
        index = 0
    }

    public var current: NavLocation { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    public mutating func push(_ loc: NavLocation) {
        guard loc != current else { return }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(loc)
        index = entries.count - 1
    }

    public mutating func back() { if canGoBack { index -= 1 } }
    public mutating func forward() { if canGoForward { index += 1 } }

    public mutating func replaceCurrent(with loc: NavLocation) { entries[index] = loc }
}

/// One tab: an identity, its own history, a pinned flag, and an optional user title.
public struct NavTab: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var history: NavHistory
    public var pinned: Bool
    public var customTitle: String?

    public init(id: UUID = UUID(), location: NavLocation, pinned: Bool = false, customTitle: String? = nil) {
        self.id = id
        self.history = NavHistory(location)
        self.pinned = pinned
        self.customTitle = customTitle
    }

    public var location: NavLocation { history.current }
}

/// One node in the sidebar's 页面 forest: either a tab leaf or a (recursive) group.
/// `Workspace.root` is the single source of truth for the sidebar's structure and
/// order; the flat `tabs` array is kept as its depth-first leaf reflection.
public indirect enum TabNode: Hashable, Sendable {
    case tab(NavTab.ID)
    case group(TabGroup)

    public var tabID: NavTab.ID? { if case .tab(let id) = self { return id } else { return nil } }
    public var group: TabGroup? { if case .group(let g) = self { return g } else { return nil } }
}

/// A typed reference to one sidebar payload, used by the multi-item drag path so
/// callers can hand the model a single ordered sequence and have it preserve the
/// interleaving (Finder-style).
public enum WorkspaceItem: Hashable, Sendable {
    case tab(NavTab.ID)
    case group(TabGroup.ID)
}

/// A named, collapsible group. `children` may interleave tabs and sub-groups to any
/// depth. `tabIDs` exposes only the *direct* tab children for callers that predate
/// nesting.
public struct TabGroup: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var children: [TabNode]
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, children: [TabNode], isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.children = children
        self.isCollapsed = isCollapsed
    }

    /// Convenience for a flat group of tabs (legacy restore + simple grouping).
    public init(id: UUID = UUID(), name: String, tabIDs: [NavTab.ID], isCollapsed: Bool = false) {
        self.init(id: id, name: name, children: tabIDs.map { .tab($0) }, isCollapsed: isCollapsed)
    }

    /// Direct child tabs (not transitive descendants) in order.
    public var tabIDs: [NavTab.ID] { children.compactMap(\.tabID) }
}

/// Legacy (v1) flat persistence of one group: member tabs by index into the flat
/// tab array. Retained for backward-compatible decoding of already-stored state.
public struct WorkspaceGroupSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var tabIndices: [Int]
    public var isCollapsed: Bool

    public init(name: String, tabIndices: [Int], isCollapsed: Bool = false) {
        self.name = name
        self.tabIndices = tabIndices
        self.isCollapsed = isCollapsed
    }
}

/// Recursive (v2) persistence of the 页面 forest. Tab leaves reference the flat tab
/// array by index; groups nest to any depth.
public struct WorkspaceTreeSnapshot: Codable, Sendable, Equatable {
    public enum Node: Codable, Sendable, Equatable {
        case tab(Int)
        case group(Group)
    }

    public struct Group: Codable, Sendable, Equatable {
        public var name: String
        public var isCollapsed: Bool
        public var children: [Node]

        public init(name: String, isCollapsed: Bool, children: [Node]) {
            self.name = name
            self.isCollapsed = isCollapsed
            self.children = children
        }
    }

    public var roots: [Node]

    public init(roots: [Node]) { self.roots = roots }
}

public struct WorkspaceSpace: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var workspace: Workspace

    public init(id: UUID = UUID(), name: String, workspace: Workspace) {
        self.id = id
        self.name = name
        self.workspace = workspace
    }
}

/// The ordered set of tabs plus which one is active. A pure value type — `AppModel`
/// holds one and `@Observable` tracks mutations through the stored property.
///
/// Two stored facts, reconciled by `normalize()`:
/// - `root`: the canonical structure + order of the sidebar 页面 forest (tabs and
///   nested groups). All structural/ordering edits go here.
/// - `tabs`: the canonical store of tab *values* (history, pinned, title) and the
///   horizontal strip order. Kept equal to the depth-first leaf order of `root`.
///
/// Invariant: every live tab id appears exactly once as a leaf in `root`.
public struct Workspace: Sendable {
    public private(set) var tabs: [NavTab]
    public private(set) var activeID: NavTab.ID
    public private(set) var root: [TabNode]

    public init(initial: NavLocation) {
        let t = NavTab(location: initial)
        tabs = [t]
        activeID = t.id
        root = [.tab(t.id)]
    }

    /// Rebuild a workspace from persisted tab snapshots + legacy (v1) flat groups.
    /// Each tab starts with a fresh single-entry history. Returns nil if empty.
    public init?(restoring tabs: [(location: NavLocation, pinned: Bool, customTitle: String?)], activeIndex: Int,
                 groups: [WorkspaceGroupSnapshot] = []) {
        guard !tabs.isEmpty else { return nil }
        let built = tabs.map { NavTab(location: $0.location, pinned: $0.pinned, customTitle: $0.customTitle) }
        self.tabs = built
        let idx = built.indices.contains(activeIndex) ? activeIndex : 0
        self.activeID = built[idx].id
        self.root = Self.buildRoot(legacyGroups: groups, tabs: built)
        normalize()
    }

    public init?(restoring tabs: [(location: NavLocation, pinned: Bool)], activeIndex: Int,
                 groups: [WorkspaceGroupSnapshot] = []) {
        self.init(restoring: tabs.map { (location: $0.location, pinned: $0.pinned, customTitle: nil) },
                  activeIndex: activeIndex,
                  groups: groups)
    }

    /// Rebuild from the recursive (v2) tree snapshot.
    public init?(restoring tabs: [(location: NavLocation, pinned: Bool, customTitle: String?)], activeIndex: Int,
                 tree: WorkspaceTreeSnapshot) {
        guard !tabs.isEmpty else { return nil }
        let built = tabs.map { NavTab(location: $0.location, pinned: $0.pinned, customTitle: $0.customTitle) }
        self.tabs = built
        let idx = built.indices.contains(activeIndex) ? activeIndex : 0
        self.activeID = built[idx].id
        self.root = Self.buildRoot(treeNodes: tree.roots, tabs: built)
        normalize()
    }

    public var activeTab: NavTab { tabs.first { $0.id == activeID } ?? tabs[0] }

    /// The recursive 页面 forest, for view code that renders nesting directly.
    public var rootNodes: [TabNode] { root }

    /// All groups at any depth (pre-order). Lookups by id work at any depth.
    public var tabGroups: [TabGroup] { Self.allGroups(in: root) }

    /// Recursive snapshot for persistence. Tab leaves reference `tabs` by index.
    public var treeSnapshot: WorkspaceTreeSnapshot {
        let indexByID = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) })
        func convert(_ nodes: [TabNode]) -> [WorkspaceTreeSnapshot.Node] {
            nodes.compactMap { node in
                switch node {
                case .tab(let id):
                    guard let i = indexByID[id] else { return nil }
                    return .tab(i)
                case .group(let g):
                    return .group(.init(name: g.name, isCollapsed: g.isCollapsed, children: convert(g.children)))
                }
            }
        }
        return WorkspaceTreeSnapshot(roots: convert(root))
    }

    private var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }

    /// The innermost group that directly contains `tabID`, if any.
    public func group(containing tabID: NavTab.ID) -> TabGroup? {
        func search(_ nodes: [TabNode]) -> TabGroup? {
            for n in nodes {
                guard case .group(let g) = n else { continue }
                if g.children.contains(where: { $0.tabID == tabID }) { return g }
                if let inner = search(g.children) { return inner }
            }
            return nil
        }
        return search(root)
    }

    public func group(_ id: TabGroup.ID) -> TabGroup? { Self.findGroup(id, in: root) }

    /// True if `id` is `ancestor` or lives anywhere in `ancestor`'s subtree. Used to
    /// reject nesting a group into its own descendant (cycle).
    public func group(_ id: TabGroup.ID, isInsideSubtreeOf ancestor: TabGroup.ID) -> Bool {
        Self.isDescendant(id, ofOrEqualTo: ancestor, in: root)
    }

    /// True if `tabID` is a leaf anywhere beneath `groupID`.
    public func group(_ groupID: TabGroup.ID, containsTab tabID: NavTab.ID) -> Bool {
        guard let g = Self.findGroup(groupID, in: root) else { return false }
        return Self.leafIDs(g.children).contains(tabID)
    }

    /// Direct tab children of a group, in order.
    public func tabs(in groupID: TabGroup.ID) -> [NavTab] {
        guard let group = Self.findGroup(groupID, in: root) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return group.tabIDs.compactMap { byID[$0] }
    }

    /// The outermost collapsed group on the path to `tabID` — i.e. the row a hidden
    /// active tab visually folds into. Nil if the tab is visible.
    public func outermostCollapsedAncestor(of tabID: NavTab.ID) -> TabGroup.ID? {
        func walk(_ nodes: [TabNode]) -> TabGroup.ID? {
            for n in nodes {
                guard case .group(let g) = n else { continue }
                guard Self.leafIDs(g.children).contains(tabID) else { continue }
                if g.isCollapsed { return g.id }
                return walk(g.children)
            }
            return nil
        }
        return walk(root)
    }

    // MARK: navigation on the active tab

    public mutating func navigateActive(to loc: NavLocation) {
        tabs[activeIndex].history.push(loc)
    }

    public mutating func backActive() { tabs[activeIndex].history.back() }
    public mutating func forwardActive() { tabs[activeIndex].history.forward() }

    // MARK: tab management

    @discardableResult
    public mutating func newTab(_ loc: NavLocation, activate: Bool = true) -> NavTab.ID {
        let t = NavTab(location: loc)
        tabs.append(t)
        root.append(.tab(t.id))
        if activate { activeID = t.id }
        return t.id
    }

    /// Remove a tab. If the removed tab was active, activate the neighbor at
    /// `min(removedIndex, lastIndex)`. Never empties the set on its own — the caller
    /// guards the last-tab case.
    public mutating func closeTab(_ id: NavTab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (id == activeID)
        tabs.remove(at: i)
        _ = Self.removeTab(id, from: &root)
        normalize()
        guard !tabs.isEmpty else {
            root = []
            return
        }
        if wasActive {
            activeID = tabs[min(i, tabs.count - 1)].id
        }
    }

    public mutating func select(_ id: NavTab.ID) {
        if tabs.contains(where: { $0.id == id }) { activeID = id }
    }

    public mutating func selectIndex(_ idx: Int) {
        if tabs.indices.contains(idx) { activeID = tabs[idx].id }
    }

    /// Move the active selection by `delta`, wrapping around the ends.
    public mutating func selectRelative(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let next = ((activeIndex + delta) % tabs.count + tabs.count) % tabs.count
        activeID = tabs[next].id
    }

    public mutating func togglePin(_ id: NavTab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].pinned.toggle()
    }

    public mutating func renameTab(_ id: NavTab.ID, to title: String?) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[i].customTitle = trimmed?.isEmpty == false ? trimmed : nil
    }

    public mutating func renameGroup(_ id: TabGroup.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Self.mutateGroup(id, in: &root) { $0.name = trimmed }
    }

    // MARK: grouping

    /// Drop `sourceID` onto `targetID` to form a new (sub)group in place. The new
    /// group `[target, source]` replaces the target leaf at its current position,
    /// inside whatever container the target lives in — root if the target is
    /// ungrouped, the target's parent group otherwise (recursively, at any depth).
    /// Same-parent drop with exactly two children is the degenerate case: the
    /// gesture would just rename/reverse the wrapper, so we keep it a no-op and
    /// preserve the outer group's name and id.
    public mutating func groupTab(_ sourceID: NavTab.ID, onto targetID: NavTab.ID) {
        guard sourceID != targetID, hasTab(sourceID), hasTab(targetID) else { return }
        let sourceGroup = group(containing: sourceID)
        let targetGroup = group(containing: targetID)
        if let sg = sourceGroup, let tg = targetGroup, sg.id == tg.id,
           let g = group(tg.id), g.children.count == 2 {
            return
        }

        _ = Self.removeTab(sourceID, from: &root)
        let groupName = nextTabGroupName()
        let newGroup = TabGroup(name: groupName, children: [.tab(targetID), .tab(sourceID)])

        if let tg = targetGroup {
            // Replace the target leaf inside its parent group with the new subgroup.
            Self.mutateGroup(tg.id, in: &root) { g in
                guard let ti = g.children.firstIndex(where: { $0.tabID == targetID }) else { return }
                g.children[ti] = .group(newGroup)
            }
        } else {
            // Target is at root: replace its root leaf with the new top-level group.
            guard let ti = root.firstIndex(where: { $0.tabID == targetID }) else { normalize(); return }
            root[ti] = .group(newGroup)
        }
        normalize()
    }

    public mutating func moveTab(_ tabID: NavTab.ID, toGroup groupID: TabGroup.ID) {
        moveTab(tabID, toGroup: groupID, at: nil)
    }

    /// Move `tabID` into `groupID` at a child index (or append). `childIndex` is
    /// interpreted against the group's children after the tab is detached.
    public mutating func moveTab(_ tabID: NavTab.ID, toGroup groupID: TabGroup.ID, at childIndex: Int?) {
        guard hasTab(tabID), Self.findGroup(groupID, in: root) != nil else { return }
        let adjusted = Self.adjustedIndex(childIndex, movingFrom: Self.locate(tab: tabID, in: root), toParent: groupID)
        _ = Self.removeTab(tabID, from: &root)
        let count = Self.findGroup(groupID, in: root)?.children.count ?? 0
        let idx = adjusted.map { min(max($0, 0), count) } ?? count
        _ = Self.insert(.tab(tabID), intoParent: groupID, at: idx, nodes: &root)
        normalize()
    }

    public mutating func moveTabToRoot(_ tabID: NavTab.ID, beforeTab targetID: NavTab.ID?) {
        guard hasTab(tabID), targetID == nil || hasTab(targetID!) else { return }
        _ = Self.removeTab(tabID, from: &root)
        let index = targetID.flatMap { Self.rootIndexOfTopLevel(containing: $0, in: root) } ?? root.count
        root.insert(.tab(tabID), at: min(max(index, 0), root.count))
        normalize()
    }

    /// Move `groupID` so it sits immediately before `targetID`, as a sibling within
    /// the target tab's actual parent (root when the target is ungrouped). No-op if
    /// the target is one of the group's own descendants.
    public mutating func moveGroup(_ groupID: TabGroup.ID, beforeTab targetID: NavTab.ID?) {
        if let targetID, group(groupID, containsTab: targetID) { return }
        guard let g = Self.removeGroup(groupID, from: &root) else { return }
        if let targetID, let (parentID, idx) = Self.locate(tab: targetID, in: root) {
            _ = Self.insert(.group(g), intoParent: parentID, at: idx, nodes: &root)
        } else {
            root.insert(.group(g), at: root.count)
        }
        normalize()
    }

    public mutating func moveGroup(_ sourceGroupID: TabGroup.ID, beforeGroup targetGroupID: TabGroup.ID) {
        guard sourceGroupID != targetGroupID,
              !Self.isDescendant(targetGroupID, ofOrEqualTo: sourceGroupID, in: root) else { return }
        guard let g = Self.removeGroup(sourceGroupID, from: &root) else { return }
        guard let (parentID, idx) = Self.locate(group: targetGroupID, in: root) else {
            root.append(.group(g)); normalize(); return
        }
        _ = Self.insert(.group(g), intoParent: parentID, at: idx, nodes: &root)
        normalize()
    }

    /// Nest `groupID` into `parentID` at a child index (or append). No-op if it would
    /// create a cycle (dropping a group into its own descendant or itself).
    public mutating func moveGroup(_ groupID: TabGroup.ID, intoGroup parentID: TabGroup.ID, at childIndex: Int? = nil) {
        guard groupID != parentID,
              !Self.isDescendant(parentID, ofOrEqualTo: groupID, in: root) else { return }
        let adjusted = Self.adjustedIndex(childIndex, movingFrom: Self.locate(group: groupID, in: root), toParent: parentID)
        guard let g = Self.removeGroup(groupID, from: &root) else { return }
        let count = Self.findGroup(parentID, in: root)?.children.count ?? 0
        let idx = adjusted.map { min(max($0, 0), count) } ?? count
        _ = Self.insert(.group(g), intoParent: parentID, at: idx, nodes: &root)
        normalize()
    }

    // MARK: batch operations (multi-select)

    /// Close every tab in `ids` that is not pinned. Each removal goes through the
    /// single-tab path so neighbor-activation and small-group dissolution behave
    /// the same as user-driven close. No-op for pinned/unknown ids.
    public mutating func closeTabs(_ ids: Set<NavTab.ID>) {
        let toClose = tabs.filter { ids.contains($0.id) && !$0.pinned }.map(\.id)
        for id in toClose { closeTab(id) }
    }

    /// Lift every selected tab in DFS order into a single new group. The new
    /// group is anchored at the **deepest common ancestor** of the selection's
    /// parents: same direct parent → that parent's slot of the earliest tab;
    /// cross-parent under some non-root group G → inside G at the slot of G's
    /// direct child that contains the earliest tab; no common group → root at
    /// the slot of the root-level ancestor of the earliest tab. Emptied parents
    /// dissolve via the normal `normalize` path. No-op unless at least two
    /// distinct tabs in `ids` exist.
    public mutating func groupTabs(_ ids: [NavTab.ID]) {
        let unique = Self.uniqued(ids).filter { hasTab($0) }
        guard unique.count >= 2 else { return }
        let position = Dictionary(uniqueKeysWithValues: Self.leafIDs(root).enumerated().map { ($0.element, $0.offset) })
        let sorted = unique.sorted { (position[$0] ?? .max) < (position[$1] ?? .max) }
        guard let earliest = sorted.first else { return }
        let lca = Self.longestCommonAncestorPath(forTabs: sorted, in: root)
        let placementParent: TabGroup.ID? = lca.last
        let placementIdx: Int
        if let parent = placementParent {
            // Find the index inside the LCA group of the direct child whose
            // subtree contains the earliest tab. For a same-parent selection
            // that's the earliest tab itself; for a cross-parent selection
            // sharing LCA G, it's the slot of G's child group that owns earliest.
            guard let g = Self.findGroup(parent, in: root),
                  let idx = Self.indexInChildren(of: g, containingTab: earliest) else { return }
            placementIdx = idx
        } else if let topIdx = Self.rootIndexOfTopLevel(containing: earliest, in: root) {
            placementIdx = topIdx
        } else {
            return
        }
        for id in sorted { _ = Self.removeTab(id, from: &root) }
        let newGroup = TabGroup(name: nextTabGroupName(), children: sorted.map { .tab($0) })
        _ = Self.insert(.group(newGroup), intoParent: placementParent, at: placementIdx, nodes: &root)
        normalize()
    }

    /// Move every tab in `ids` (in input order) into `groupID`, anchoring the run
    /// at `childIndex` (or the end). Detach-then-insert in one pass so callers
    /// don't see intermediate single-tab states.
    public mutating func moveTabs(_ ids: [NavTab.ID], toGroup groupID: TabGroup.ID, at childIndex: Int?) {
        let unique = Self.uniqued(ids).filter { hasTab($0) }
        guard !unique.isEmpty, Self.findGroup(groupID, in: root) != nil else { return }
        // Match `moveTab`'s adjustedIndex semantics: when a source sat in the
        // target parent at an index < childIndex, detaching it shifts the slot.
        let originalLocations = unique.map { Self.locate(tab: $0, in: root) }
        for id in unique { _ = Self.removeTab(id, from: &root) }
        let count = Self.findGroup(groupID, in: root)?.children.count ?? 0
        let baseTarget: Int = {
            guard let raw = childIndex else { return count }
            let sameParentBefore = originalLocations
                .compactMap { $0 }
                .filter { $0.0 == groupID && $0.1 < raw }
                .count
            return min(max(raw - sameParentBefore, 0), count)
        }()
        var insertAt = baseTarget
        for id in unique {
            _ = Self.insert(.tab(id), intoParent: groupID, at: insertAt, nodes: &root)
            insertAt += 1
        }
        normalize()
    }

    /// Move a heterogeneous, visual-order sequence of items into `groupID`. Tabs
    /// and groups stay interleaved exactly as supplied — Finder-style preservation
    /// of mixed selection order during a multi-drag (QUA-100). Items that would
    /// cycle (a group dropped into its own descendant) are skipped silently.
    public mutating func moveItems(_ items: [WorkspaceItem], toGroup groupID: TabGroup.ID, at childIndex: Int?) {
        let unique = Self.uniquedItems(items).filter { existsItem($0) }
        guard !unique.isEmpty, Self.findGroup(groupID, in: root) != nil else { return }
        let originalLocs = unique.map { Self.locateItem($0, in: root) }
        var detached: [TabNode] = []
        for item in unique {
            switch item {
            case .tab(let id):
                if Self.removeTab(id, from: &root) { detached.append(.tab(id)) }
            case .group(let id):
                guard !Self.isDescendant(groupID, ofOrEqualTo: id, in: root) else { continue }
                if let g = Self.removeGroup(id, from: &root) { detached.append(.group(g)) }
            }
        }
        let count = Self.findGroup(groupID, in: root)?.children.count ?? 0
        let baseTarget: Int = {
            guard let raw = childIndex else { return count }
            let sameParentBefore = originalLocs.compactMap { $0 }.filter { $0.0 == groupID && $0.1 < raw }.count
            return min(max(raw - sameParentBefore, 0), count)
        }()
        var insertAt = baseTarget
        for node in detached {
            _ = Self.insert(node, intoParent: groupID, at: insertAt, nodes: &root)
            insertAt += 1
        }
        normalize()
    }

    /// Move a heterogeneous, visual-order sequence of items into root at `index`
    /// (or append). Order is preserved exactly — see `moveItems(_:toGroup:at:)`.
    public mutating func moveItemsToRoot(_ items: [WorkspaceItem], at index: Int?) {
        let unique = Self.uniquedItems(items).filter { existsItem($0) }
        guard !unique.isEmpty else { return }
        let originalLocs = unique.map { Self.locateItem($0, in: root) }
        var detached: [TabNode] = []
        for item in unique {
            switch item {
            case .tab(let id):
                if Self.removeTab(id, from: &root) { detached.append(.tab(id)) }
            case .group(let id):
                if let g = Self.removeGroup(id, from: &root) { detached.append(.group(g)) }
            }
        }
        let baseTarget: Int = {
            guard let raw = index else { return root.count }
            let sameRootBefore = originalLocs.compactMap { $0 }.filter { $0.0 == nil && $0.1 < raw }.count
            return min(max(raw - sameRootBefore, 0), root.count)
        }()
        var insertAt = baseTarget
        for node in detached {
            root.insert(node, at: min(insertAt, root.count))
            insertAt += 1
        }
        normalize()
    }

    private func existsItem(_ item: WorkspaceItem) -> Bool {
        switch item {
        case .tab(let id): return hasTab(id)
        case .group(let id): return Self.findGroup(id, in: root) != nil
        }
    }

    private static func uniquedItems(_ items: [WorkspaceItem]) -> [WorkspaceItem] {
        var seen: Set<WorkspaceItem> = []
        return items.filter { seen.insert($0).inserted }
    }

    private static func locateItem(_ item: WorkspaceItem, in nodes: [TabNode]) -> (TabGroup.ID?, Int)? {
        switch item {
        case .tab(let id): return locate(tab: id, in: nodes)
        case .group(let id): return locate(group: id, in: nodes)
        }
    }

    /// Bulk reorder a list of tabs into root, anchoring at `index` (or appending).
    /// Same adjusted-index trick as `moveTabs` so a same-parent target slot doesn't
    /// drift when sources detach from earlier indices in that parent.
    public mutating func moveTabsToRoot(_ ids: [NavTab.ID], at index: Int?) {
        let unique = Self.uniqued(ids).filter { hasTab($0) }
        guard !unique.isEmpty else { return }
        let originalLocs = unique.map { Self.locate(tab: $0, in: root) }
        for id in unique { _ = Self.removeTab(id, from: &root) }
        let baseTarget: Int = {
            guard let raw = index else { return root.count }
            let sameRootBefore = originalLocs.compactMap { $0 }.filter { $0.0 == nil && $0.1 < raw }.count
            return min(max(raw - sameRootBefore, 0), root.count)
        }()
        var insertAt = baseTarget
        for id in unique {
            root.insert(.tab(id), at: min(insertAt, root.count))
            insertAt += 1
        }
        normalize()
    }

    /// Bulk reparent groups to root in the given order at `index` (or end). Each
    /// detaches in turn so the same adjusted-index logic applies.
    public mutating func moveGroupsToRoot(_ ids: [TabGroup.ID], at index: Int?) {
        let unique = Self.uniqued(ids).filter { Self.findGroup($0, in: root) != nil }
        guard !unique.isEmpty else { return }
        let originalLocs = unique.map { Self.locate(group: $0, in: root) }
        var detached: [TabGroup] = []
        for id in unique {
            if let g = Self.removeGroup(id, from: &root) { detached.append(g) }
        }
        let baseTarget: Int = {
            guard let raw = index else { return root.count }
            let sameRootBefore = originalLocs.compactMap { $0 }.filter { $0.0 == nil && $0.1 < raw }.count
            return min(max(raw - sameRootBefore, 0), root.count)
        }()
        var insertAt = baseTarget
        for g in detached {
            root.insert(.group(g), at: min(insertAt, root.count))
            insertAt += 1
        }
        normalize()
    }

    /// "上级胜出": when a multi-drag selection contains both an ancestor group
    /// and its descendant tabs/groups, drop the descendants — moving the
    /// container already moves them implicitly. Pure function so the DnD path
    /// can call it without mutating state.
    public func payloadAncestorFilter(tabIDs: [NavTab.ID],
                                      groupIDs: [TabGroup.ID]) -> (tabs: [NavTab.ID], groups: [TabGroup.ID]) {
        let groupSet = Set(groupIDs)
        let tabs = tabIDs.filter { id in
            !groupSet.contains { gid in group(gid, containsTab: id) }
        }
        let groups = groupIDs.filter { gid in
            !groupSet.contains { other in other != gid && group(gid, isInsideSubtreeOf: other) }
        }
        return (tabs, groups)
    }

    private static func uniqued<T: Hashable>(_ ids: [T]) -> [T] {
        var seen: Set<T> = []
        return ids.filter { seen.insert($0).inserted }
    }

    public mutating func moveGroupToRoot(_ groupID: TabGroup.ID, at index: Int? = nil) {
        let adjusted = Self.adjustedIndex(index, movingFrom: Self.locate(group: groupID, in: root), toParent: nil)
        guard let g = Self.removeGroup(groupID, from: &root) else { return }
        let idx = adjusted.map { min(max($0, 0), root.count) } ?? root.count
        root.insert(.group(g), at: idx)
        normalize()
    }

    public mutating func toggleGroupCollapsed(_ groupID: TabGroup.ID) {
        Self.mutateGroup(groupID, in: &root) { $0.isCollapsed.toggle() }
    }

    public mutating func setGroupCollapsed(_ groupID: TabGroup.ID, collapsed: Bool) {
        Self.mutateGroup(groupID, in: &root) { $0.isCollapsed = collapsed }
    }

    /// Reorder all tabs to match `ids` (the order produced by a strip drag). Tree
    /// structure is preserved: every sibling list is re-sorted by the new rank of its
    /// earliest descendant, keeping groups contiguous. `ids` must be a permutation of
    /// the current tab ids — anything else is a no-op. The active tab is unchanged.
    public mutating func reorder(_ ids: [NavTab.ID]) {
        guard ids.count == tabs.count, Set(ids) == Set(tabs.map(\.id)) else { return }
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        root = Self.sortByRank(root, rank: rank)
        syncTabsToTree()
    }

    /// Null out the current open path of any tab whose open file is no longer in
    /// the index (e.g. deleted/moved between launches). Pane is preserved.
    public mutating func pruneOpenPaths(validPaths: Set<String>) {
        for i in tabs.indices {
            let loc = tabs[i].history.current
            if let p = loc.openPath, !validPaths.contains(p) {
                tabs[i].history.replaceCurrent(with: NavLocation(pane: loc.pane, openPath: nil))
            }
        }
    }

    private func hasTab(_ id: NavTab.ID) -> Bool { tabs.contains { $0.id == id } }

    private func nextTabGroupName() -> String {
        let prefix = "页面组 "
        let used = Set(Self.allGroups(in: root).compactMap { group -> Int? in
            let name = Self.migratedGroupName(group.name)
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count))
        })
        var n = 1
        while used.contains(n) { n += 1 }
        return "\(prefix)\(n)"
    }

    private static func migratedGroupName(_ name: String) -> String {
        let oldPrefix = "标签组 "
        let newPrefix = "页面组 "
        guard name.hasPrefix(oldPrefix),
              let number = Int(name.dropFirst(oldPrefix.count)) else { return name }
        return "\(newPrefix)\(number)"
    }

    // MARK: normalization

    /// Reconcile structure with tab membership, then mirror the flat array to the
    /// tree's depth-first leaf order. Idempotent.
    private mutating func normalize() {
        let valid = Set(tabs.map(\.id))
        var seen: Set<NavTab.ID> = []
        root = Self.prune(root, valid: valid, seen: &seen)
        let missing = tabs.map(\.id).filter { !seen.contains($0) }
        root.append(contentsOf: missing.map { TabNode.tab($0) })
        root = Self.dissolveSmall(root)
        syncTabsToTree()
    }

    /// Drop leaves with no backing tab and any duplicate occurrences (keeping the
    /// first), enforcing "every live tab appears exactly once in root".
    private static func prune(_ nodes: [TabNode], valid: Set<NavTab.ID>, seen: inout Set<NavTab.ID>) -> [TabNode] {
        nodes.compactMap { node in
            switch node {
            case .tab(let id):
                guard valid.contains(id), seen.insert(id).inserted else { return nil }
                return node
            case .group(var g):
                g.children = prune(g.children, valid: valid, seen: &seen)
                return .group(g)
            }
        }
    }

    /// Bottom-up, dissolve any group with fewer than two children by promoting its
    /// remaining children into the parent's position. Cascades naturally.
    private static func dissolveSmall(_ nodes: [TabNode]) -> [TabNode] {
        var out: [TabNode] = []
        for node in nodes {
            switch node {
            case .tab:
                out.append(node)
            case .group(var g):
                let resolved = dissolveSmall(g.children)
                if resolved.count < 2 {
                    out.append(contentsOf: resolved)
                } else {
                    g.children = resolved
                    out.append(.group(g))
                }
            }
        }
        return out
    }

    private mutating func syncTabsToTree() {
        let order = Self.leafIDs(root)
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        tabs = order.compactMap { byID[$0] }
    }

    // MARK: tree helpers

    private static func allGroups(in nodes: [TabNode]) -> [TabGroup] {
        var out: [TabGroup] = []
        for n in nodes {
            guard case .group(let g) = n else { continue }
            out.append(g)
            out.append(contentsOf: allGroups(in: g.children))
        }
        return out
    }

    private static func findGroup(_ id: TabGroup.ID, in nodes: [TabNode]) -> TabGroup? {
        for n in nodes {
            guard case .group(let g) = n else { continue }
            if g.id == id { return g }
            if let inner = findGroup(id, in: g.children) { return inner }
        }
        return nil
    }

    private static func leafIDs(_ nodes: [TabNode]) -> [NavTab.ID] {
        var out: [NavTab.ID] = []
        for n in nodes {
            switch n {
            case .tab(let id): out.append(id)
            case .group(let g): out.append(contentsOf: leafIDs(g.children))
            }
        }
        return out
    }

    @discardableResult
    private static func removeTab(_ id: NavTab.ID, from nodes: inout [TabNode]) -> Bool {
        var removed = false
        nodes = nodes.compactMap { node in
            switch node {
            case .tab(let t):
                if t == id { removed = true; return nil }
                return node
            case .group(var g):
                if removeTab(id, from: &g.children) { removed = true }
                return .group(g)
            }
        }
        return removed
    }

    @discardableResult
    private static func removeGroup(_ id: TabGroup.ID, from nodes: inout [TabNode]) -> TabGroup? {
        var found: TabGroup?
        nodes = nodes.compactMap { node in
            switch node {
            case .tab:
                return node
            case .group(var g):
                if g.id == id { found = g; return nil }
                if let inner = removeGroup(id, from: &g.children) { found = inner }
                return .group(g)
            }
        }
        return found
    }

    /// Insert `node` into `parentID`'s children at `index`, or at root when `parentID`
    /// is nil. Returns whether the parent was found.
    @discardableResult
    private static func insert(_ node: TabNode, intoParent parentID: TabGroup.ID?, at index: Int,
                               nodes: inout [TabNode]) -> Bool {
        guard let parentID else {
            nodes.insert(node, at: min(max(index, 0), nodes.count))
            return true
        }
        var done = false
        for i in nodes.indices {
            guard case .group(var g) = nodes[i] else { continue }
            if g.id == parentID {
                g.children.insert(node, at: min(max(index, 0), g.children.count))
                nodes[i] = .group(g)
                return true
            }
            if insert(node, intoParent: parentID, at: index, nodes: &g.children) {
                nodes[i] = .group(g)
                done = true
                break
            }
        }
        return done
    }

    @discardableResult
    private static func mutateGroup(_ id: TabGroup.ID, in nodes: inout [TabNode],
                                    _ body: (inout TabGroup) -> Void) -> Bool {
        for i in nodes.indices {
            guard case .group(var g) = nodes[i] else { continue }
            if g.id == id {
                body(&g)
                nodes[i] = .group(g)
                return true
            }
            if mutateGroup(id, in: &g.children, body) {
                nodes[i] = .group(g)
                return true
            }
        }
        return false
    }

    /// True if `candidate` is `ancestor` or lives anywhere in `ancestor`'s subtree.
    private static func isDescendant(_ candidate: TabGroup.ID, ofOrEqualTo ancestor: TabGroup.ID,
                                     in nodes: [TabNode]) -> Bool {
        if candidate == ancestor { return true }
        guard let g = findGroup(ancestor, in: nodes) else { return false }
        return allGroups(in: g.children).contains { $0.id == candidate }
    }

    /// The root index of the top-level node whose subtree contains `tabID`.
    private static func rootIndexOfTopLevel(containing tabID: NavTab.ID, in nodes: [TabNode]) -> Int? {
        nodes.firstIndex { leafIDs([$0]).contains(tabID) }
    }

    /// Ancestor group ids on the path from root to `tabID`, outermost first
    /// (root-level group → immediate parent). Empty when the tab is at root or
    /// missing. Used by LCA placement.
    private static func ancestorGroupPath(of tabID: NavTab.ID, in nodes: [TabNode],
                                          accumulator: [TabGroup.ID] = []) -> [TabGroup.ID]? {
        for node in nodes {
            switch node {
            case .tab(let id):
                if id == tabID { return accumulator }
            case .group(let g):
                if let inner = ancestorGroupPath(of: tabID, in: g.children,
                                                 accumulator: accumulator + [g.id]) {
                    return inner
                }
            }
        }
        return nil
    }

    /// Longest common ancestor-group path across `tabs`. Empty array means root
    /// is the only common ancestor. Missing tabs are skipped (callers filter).
    static func longestCommonAncestorPath(forTabs tabs: [NavTab.ID],
                                          in nodes: [TabNode]) -> [TabGroup.ID] {
        let paths = tabs.compactMap { ancestorGroupPath(of: $0, in: nodes) }
        guard let first = paths.first else { return [] }
        var prefix = first
        for path in paths.dropFirst() {
            let limit = min(prefix.count, path.count)
            var i = 0
            while i < limit, prefix[i] == path[i] { i += 1 }
            prefix = Array(prefix.prefix(i))
            if prefix.isEmpty { break }
        }
        return prefix
    }

    /// Inside `group`, the child index of the direct child whose subtree
    /// contains `tabID`. Nil if not found.
    static func indexInChildren(of group: TabGroup, containingTab tabID: NavTab.ID) -> Int? {
        group.children.firstIndex { node in
            switch node {
            case .tab(let id): return id == tabID
            case .group(let g): return leafIDs(g.children).contains(tabID)
            }
        }
    }

    /// The (parentID?, childIndex) location of a group.
    private static func locate(group id: TabGroup.ID, in nodes: [TabNode],
                               parent: TabGroup.ID? = nil) -> (TabGroup.ID?, Int)? {
        for (i, node) in nodes.enumerated() {
            guard case .group(let g) = node else { continue }
            if g.id == id { return (parent, i) }
            if let inner = locate(group: id, in: g.children, parent: g.id) { return inner }
        }
        return nil
    }

    /// The (parentID?, childIndex) location of a tab leaf.
    private static func locate(tab id: NavTab.ID, in nodes: [TabNode],
                               parent: TabGroup.ID? = nil) -> (TabGroup.ID?, Int)? {
        for (i, node) in nodes.enumerated() {
            switch node {
            case .tab(let t):
                if t == id { return (parent, i) }
            case .group(let g):
                if let inner = locate(tab: id, in: g.children, parent: g.id) { return inner }
            }
        }
        return nil
    }

    /// When an item moves *within the same parent* to a later slot, the drop index
    /// (computed before detaching) is one too high once the item is removed.
    private static func adjustedIndex(_ childIndex: Int?, movingFrom source: (TabGroup.ID?, Int)?,
                                      toParent parentID: TabGroup.ID?) -> Int? {
        guard let childIndex, let (sourceParent, sourceIdx) = source,
              sourceParent == parentID, sourceIdx < childIndex else { return childIndex }
        return childIndex - 1
    }

    private static func minRank(_ node: TabNode, _ rank: [NavTab.ID: Int]) -> Int {
        switch node {
        case .tab(let id): return rank[id] ?? Int.max
        case .group(let g): return g.children.map { minRank($0, rank) }.min() ?? Int.max
        }
    }

    private static func sortByRank(_ nodes: [TabNode], rank: [NavTab.ID: Int]) -> [TabNode] {
        let recursed = nodes.enumerated().map { offset, node -> (Int, TabNode) in
            guard case .group(var g) = node else { return (offset, node) }
            g.children = sortByRank(g.children, rank: rank)
            return (offset, .group(g))
        }
        return recursed.sorted { lhs, rhs in
            let a = minRank(lhs.1, rank), b = minRank(rhs.1, rank)
            return a != b ? a < b : lhs.0 < rhs.0   // stable: keep original order on ties
        }.map(\.1)
    }

    // MARK: restore builders

    private static func buildRoot(legacyGroups groups: [WorkspaceGroupSnapshot], tabs: [NavTab]) -> [TabNode] {
        var groupAtFirstIndex: [Int: TabGroup] = [:]
        var grouped = Set<Int>()
        for snap in groups {
            var seen = Set<Int>()
            let members = snap.tabIndices.filter { tabs.indices.contains($0) && seen.insert($0).inserted }
            let fresh = members.filter { !grouped.contains($0) }
            guard fresh.count >= 1, let first = fresh.min() else { continue }
            for m in fresh { grouped.insert(m) }
            let memberIDs = members.filter { fresh.contains($0) }.map { tabs[$0].id }
            groupAtFirstIndex[first] = TabGroup(name: migratedGroupName(snap.name),
                                                tabIDs: memberIDs,
                                                isCollapsed: snap.isCollapsed)
        }
        var out: [TabNode] = []
        for i in tabs.indices {
            if let g = groupAtFirstIndex[i] {
                out.append(.group(g))
            } else if !grouped.contains(i) {
                out.append(.tab(tabs[i].id))
            }
        }
        return out
    }

    private static func buildRoot(treeNodes: [WorkspaceTreeSnapshot.Node], tabs: [NavTab]) -> [TabNode] {
        treeNodes.compactMap { node in
            switch node {
            case .tab(let i):
                guard tabs.indices.contains(i) else { return nil }
                return .tab(tabs[i].id)
            case .group(let g):
                return .group(TabGroup(name: migratedGroupName(g.name),
                                       children: buildRoot(treeNodes: g.children, tabs: tabs),
                                       isCollapsed: g.isCollapsed))
            }
        }
    }
}
