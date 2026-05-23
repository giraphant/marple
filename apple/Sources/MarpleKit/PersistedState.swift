import Foundation

/// One restored tab: its current location plus pinned flag. Histories are not
/// persisted — a restored tab starts with a fresh single-entry history.
public struct PersistedTab: Codable, Sendable, Equatable {
    public var location: NavLocation
    public var pinned: Bool
    public init(location: NavLocation, pinned: Bool) {
        self.location = location; self.pinned = pinned
    }
}

/// A launch-to-launch snapshot of the user's place: open tabs + the active one,
/// plus the global browse controls. `browseMode` is a raw string so MarpleKit
/// stays agnostic of the app target's `BrowseMode` enum.
public struct PersistedState: Codable, Sendable, Equatable {
    public var tabs: [PersistedTab]
    public var activeIndex: Int
    public var sortClauses: [SortClause]
    public var filterClauses: [FilterClause]
    public var filterMatch: FilterMatch
    public var browseMode: String

    public init(tabs: [PersistedTab], activeIndex: Int, sortClauses: [SortClause],
                filterClauses: [FilterClause], filterMatch: FilterMatch, browseMode: String) {
        self.tabs = tabs; self.activeIndex = activeIndex
        self.sortClauses = sortClauses; self.filterClauses = filterClauses
        self.filterMatch = filterMatch; self.browseMode = browseMode
    }

    public func makeWorkspace() -> Workspace? {
        Workspace(restoring: tabs.map { (location: $0.location, pinned: $0.pinned) },
                  activeIndex: activeIndex)
    }
}

/// Where persisted state lives. App uses UserDefaults; tests can substitute.
public protocol StateStore: Sendable {
    func load() -> PersistedState?
    func save(_ state: PersistedState)
}

public struct UserDefaultsStateStore: StateStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "marple.persistedState") {
        self.defaults = defaults; self.key = key
    }
    public func load() -> PersistedState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }
    public func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
