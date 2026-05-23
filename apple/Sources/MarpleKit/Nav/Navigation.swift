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

/// One tab: an identity, its own history, and a pinned flag.
public struct NavTab: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var history: NavHistory
    public var pinned: Bool

    public init(id: UUID = UUID(), location: NavLocation, pinned: Bool = false) {
        self.id = id
        self.history = NavHistory(location)
        self.pinned = pinned
    }

    public var location: NavLocation { history.current }
}

/// The ordered set of tabs plus which one is active. A pure value type — `AppModel`
/// holds one and `@Observable` tracks mutations through the stored property.
public struct Workspace: Sendable {
    public private(set) var tabs: [NavTab]
    public private(set) var activeID: NavTab.ID

    public init(initial: NavLocation) {
        let t = NavTab(location: initial)
        tabs = [t]
        activeID = t.id
    }

    /// Rebuild a workspace from persisted tab snapshots. Each tab starts with a
    /// fresh single-entry history at its saved location. Returns nil if empty.
    public init?(restoring tabs: [(location: NavLocation, pinned: Bool)], activeIndex: Int) {
        guard !tabs.isEmpty else { return nil }
        let built = tabs.map { NavTab(location: $0.location, pinned: $0.pinned) }
        self.tabs = built
        let idx = built.indices.contains(activeIndex) ? activeIndex : 0
        self.activeID = built[idx].id
    }

    public var activeTab: NavTab { tabs.first { $0.id == activeID } ?? tabs[0] }

    private var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }

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
        guard !tabs.isEmpty else { return }
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

    /// Reorder the tabs to match `ids` (the order produced by a drag). `ids` must be
    /// a permutation of the current tab ids — anything else (incomplete / unknown /
    /// duplicate) is a no-op. The active tab is unchanged.
    public mutating func reorder(_ ids: [NavTab.ID]) {
        guard ids.count == tabs.count, Set(ids) == Set(tabs.map(\.id)) else { return }
        let map = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        tabs = ids.compactMap { map[$0] }
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
}
