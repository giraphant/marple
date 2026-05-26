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

public struct TabGroup: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var tabIDs: [NavTab.ID]
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, tabIDs: [NavTab.ID], isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.tabIDs = tabIDs
        self.isCollapsed = isCollapsed
    }
}

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
public struct Workspace: Sendable {
    public private(set) var tabs: [NavTab]
    public private(set) var activeID: NavTab.ID
    public private(set) var tabGroups: [TabGroup]

    public init(initial: NavLocation) {
        let t = NavTab(location: initial)
        tabs = [t]
        activeID = t.id
        tabGroups = []
    }

    /// Rebuild a workspace from persisted tab snapshots. Each tab starts with a
    /// fresh single-entry history at its saved location. Returns nil if empty.
    public init?(restoring tabs: [(location: NavLocation, pinned: Bool, customTitle: String?)], activeIndex: Int,
                 groups: [WorkspaceGroupSnapshot] = []) {
        guard !tabs.isEmpty else { return nil }
        let built = tabs.map { NavTab(location: $0.location, pinned: $0.pinned, customTitle: $0.customTitle) }
        self.tabs = built
        let idx = built.indices.contains(activeIndex) ? activeIndex : 0
        self.activeID = built[idx].id
        self.tabGroups = groups.map { snapshot in
            let ids = snapshot.tabIndices.compactMap { built.indices.contains($0) ? built[$0].id : nil }
            return TabGroup(name: Self.migratedGroupName(snapshot.name), tabIDs: ids, isCollapsed: snapshot.isCollapsed)
        }
        normalizeGroups()
    }

    public init?(restoring tabs: [(location: NavLocation, pinned: Bool)], activeIndex: Int,
                 groups: [WorkspaceGroupSnapshot] = []) {
        self.init(restoring: tabs.map { (location: $0.location, pinned: $0.pinned, customTitle: nil) },
                  activeIndex: activeIndex,
                  groups: groups)
    }

    public var activeTab: NavTab { tabs.first { $0.id == activeID } ?? tabs[0] }

    public var groupSnapshots: [WorkspaceGroupSnapshot] {
        let positions = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) })
        return tabGroups.compactMap { group in
            let indices = group.tabIDs.compactMap { positions[$0] }
            guard indices.count >= 2 else { return nil }
            return WorkspaceGroupSnapshot(name: group.name, tabIndices: indices, isCollapsed: group.isCollapsed)
        }
    }

    private var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }

    public func group(containing tabID: NavTab.ID) -> TabGroup? {
        tabGroups.first { $0.tabIDs.contains(tabID) }
    }

    public func tabs(in groupID: TabGroup.ID) -> [NavTab] {
        guard let group = tabGroups.first(where: { $0.id == groupID }) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return group.tabIDs.compactMap { byID[$0] }
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
        removeTabFromGroups(id)
        normalizeGroups()
        guard !tabs.isEmpty else {
            tabGroups = []
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
        guard let i = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabGroups[i].name = trimmed
    }

    public mutating func groupTab(_ sourceID: NavTab.ID, onto targetID: NavTab.ID) {
        guard sourceID != targetID, tabExists(sourceID), tabExists(targetID) else { return }
        if let sourceGroup = group(containing: sourceID),
           let targetGroup = group(containing: targetID),
           sourceGroup.id == targetGroup.id {
            return
        }
        if let targetGroup = group(containing: targetID) {
            moveTab(sourceID, toGroup: targetGroup.id)
            return
        }
        removeTabFromGroups(sourceID)
        normalizeGroups()
        moveTabInOrder(sourceID, after: targetID)
        tabGroups.append(TabGroup(name: nextTabGroupName(), tabIDs: [targetID, sourceID]))
        normalizeGroups()
    }

    public mutating func moveTab(_ tabID: NavTab.ID, toGroup groupID: TabGroup.ID) {
        moveTab(tabID, toGroup: groupID, at: nil)
    }

    public mutating func moveTab(_ tabID: NavTab.ID, toGroup groupID: TabGroup.ID, at childIndex: Int?) {
        guard tabExists(tabID), tabGroups.contains(where: { $0.id == groupID }) else { return }
        let currentGroupID = group(containing: tabID)?.id
        if currentGroupID != groupID {
            removeTabFromGroups(tabID)
            normalizeGroups()
        }
        guard let idx = tabGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var ids = tabGroups[idx].tabIDs.filter { $0 != tabID }
        let referenceIDs = ids
        let insertAt = min(max(childIndex ?? ids.count, 0), ids.count)
        ids.insert(tabID, at: insertAt)
        tabGroups[idx].tabIDs = ids
        placeTabs(ids, atEarliestPositionOf: referenceIDs.isEmpty ? ids : referenceIDs)
        normalizeGroups()
    }

    public mutating func moveTabToRoot(_ tabID: NavTab.ID, beforeTab targetID: NavTab.ID?) {
        guard tabExists(tabID), targetID == nil || tabExists(targetID!) else { return }
        removeTabFromGroups(tabID)
        normalizeGroups()
        moveTabInOrder(tabID, before: targetID)
    }

    public mutating func moveGroup(_ groupID: TabGroup.ID, beforeTab targetID: NavTab.ID?) {
        guard let group = tabGroups.first(where: { $0.id == groupID }) else { return }
        if let targetID, group.tabIDs.contains(targetID) { return }
        let target = targetID.flatMap { self.group(containing: $0)?.tabIDs.first ?? $0 }
        moveTabsInOrder(group.tabIDs, before: target)
        normalizeGroups()
    }

    public mutating func moveGroup(_ sourceGroupID: TabGroup.ID, beforeGroup targetGroupID: TabGroup.ID) {
        guard sourceGroupID != targetGroupID,
              let target = tabGroups.first(where: { $0.id == targetGroupID })?.tabIDs.first else { return }
        moveGroup(sourceGroupID, beforeTab: target)
    }

    public mutating func toggleGroupCollapsed(_ groupID: TabGroup.ID) {
        guard let idx = tabGroups.firstIndex(where: { $0.id == groupID }) else { return }
        tabGroups[idx].isCollapsed.toggle()
    }

    public mutating func setGroupCollapsed(_ groupID: TabGroup.ID, collapsed: Bool) {
        guard let idx = tabGroups.firstIndex(where: { $0.id == groupID }) else { return }
        tabGroups[idx].isCollapsed = collapsed
    }

    /// Reorder the tabs to match `ids` (the order produced by a drag). `ids` must be
    /// a permutation of the current tab ids — anything else (incomplete / unknown /
    /// duplicate) is a no-op. The active tab is unchanged.
    public mutating func reorder(_ ids: [NavTab.ID]) {
        guard ids.count == tabs.count, Set(ids) == Set(tabs.map(\.id)) else { return }
        let map = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        tabs = ids.compactMap { map[$0] }
        normalizeGroups()
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

    private func tabExists(_ id: NavTab.ID) -> Bool {
        tabs.contains { $0.id == id }
    }

    private func tabIDsInCurrentOrder(_ ids: Set<NavTab.ID>) -> [NavTab.ID] {
        tabs.map(\.id).filter { ids.contains($0) }
    }

    private mutating func moveTabInOrder(_ tabID: NavTab.ID, after anchorID: NavTab.ID) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }),
              let anchor = tabs.firstIndex(where: { $0.id == anchorID }) else { return }
        let tab = tabs.remove(at: from)
        let anchorAfterRemoval = tabs.firstIndex(where: { $0.id == anchorID }) ?? max(0, anchor - 1)
        tabs.insert(tab, at: min(anchorAfterRemoval + 1, tabs.count))
    }

    private mutating func moveTabInOrder(_ tabID: NavTab.ID, before targetID: NavTab.ID?) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs.remove(at: from)
        let targetIndex = targetID.flatMap { target in tabs.firstIndex { $0.id == target } } ?? tabs.count
        tabs.insert(tab, at: targetIndex)
    }

    private mutating func moveTabsInOrder(_ movingIDs: [NavTab.ID], before targetID: NavTab.ID?) {
        let moving = Set(movingIDs)
        let block = tabs.filter { moving.contains($0.id) }
        guard !block.isEmpty else { return }
        tabs.removeAll { moving.contains($0.id) }
        let targetIndex = targetID.flatMap { target in tabs.firstIndex { $0.id == target } } ?? tabs.count
        tabs.insert(contentsOf: block, at: targetIndex)
    }

    private mutating func placeTabs(_ ids: [NavTab.ID], atEarliestPositionOf referenceIDs: [NavTab.ID]) {
        let moving = Set(ids)
        let block = ids.compactMap { id in tabs.first { $0.id == id } }
        guard !block.isEmpty else { return }
        let referencePositions = referenceIDs.compactMap { id in tabs.firstIndex { $0.id == id } }
        let insertion = referencePositions.min() ?? tabs.count
        tabs.removeAll { moving.contains($0.id) }
        tabs.insert(contentsOf: block, at: min(insertion, tabs.count))
    }

    private func nextTabGroupName() -> String {
        let prefix = "页面组 "
        let used = Set(tabGroups.compactMap { group -> Int? in
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

    private mutating func removeTabFromGroups(_ id: NavTab.ID) {
        for i in tabGroups.indices {
            tabGroups[i].tabIDs.removeAll { $0 == id }
        }
    }

    private mutating func normalizeGroups() {
        var seen: Set<NavTab.ID> = []
        let orderedIDs = tabs.map(\.id)
        for i in tabGroups.indices {
            let wanted = Set(tabGroups[i].tabIDs)
            tabGroups[i].tabIDs = orderedIDs.filter { wanted.contains($0) && seen.insert($0).inserted }
        }
        tabGroups.removeAll { $0.tabIDs.count < 2 }
        let positions = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        tabGroups.sort {
            (positions[$0.tabIDs[0]] ?? Int.max) < (positions[$1.tabIDs[0]] ?? Int.max)
        }
    }
}
