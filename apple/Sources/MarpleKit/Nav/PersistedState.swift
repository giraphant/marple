import Foundation

/// One restored tab: its current location plus pinned flag. Histories are not
/// persisted — a restored tab starts with a fresh single-entry history.
///
/// `cachedTitle` is a session-to-session snapshot of `entry.title` for the tab's
/// path, written at persist time and read at the next launch BEFORE `entries`
/// has loaded. Without it, the sidebar tab list would show bare filenames like
/// `00-overview.md` during bootstrap (because the live `entry?.title` lookup
/// returns nil against an empty entries array). Decoded as nil on legacy state
/// that predates this field, falling through to the existing filename fallback.
public struct PersistedTab: Codable, Sendable, Equatable {
    public var location: NavLocation
    public var pinned: Bool
    public var customTitle: String?
    public var cachedTitle: String?
    /// Snapshot of `entry.type` for the bootstrap window — paired with
    /// `cachedTitle`, this is what lets the sidebar render the correct
    /// type icon (paper / note / book / image / chapter / theme) instead of
    /// falling back to the default `list.bullet` while `entries` is empty.
    /// Decoded as nil on legacy state predating this field. QUA-105.
    public var cachedType: EntryType?
    public init(location: NavLocation, pinned: Bool,
                customTitle: String? = nil,
                cachedTitle: String? = nil,
                cachedType: EntryType? = nil) {
        self.location = location
        self.pinned = pinned
        self.customTitle = customTitle
        self.cachedTitle = cachedTitle
        self.cachedType = cachedType
    }
}

public struct PersistedWorkspaceSpace: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var isBrowsing: Bool
    public var tabs: [PersistedTab]
    public var activeIndex: Int
    public var iconName: String?
    /// Legacy (v1) flat groups. Still decoded from already-stored state; new saves
    /// leave this empty and use `tree`.
    public var groups: [WorkspaceGroupSnapshot]
    /// Recursive (v2) forest. Present in new saves; absent in legacy state.
    public var tree: WorkspaceTreeSnapshot?

    public init(id: UUID = UUID(), name: String = "默认 Space", isBrowsing: Bool = false,
                tabs: [PersistedTab] = [], activeIndex: Int = 0,
                iconName: String? = nil,
                groups: [WorkspaceGroupSnapshot] = [], tree: WorkspaceTreeSnapshot? = nil) {
        self.id = id
        self.name = name
        self.isBrowsing = isBrowsing
        self.tabs = tabs
        self.activeIndex = activeIndex
        self.iconName = iconName
        self.groups = groups
        self.tree = tree
    }

    enum CodingKeys: String, CodingKey { case id, name, isBrowsing, tabs, activeIndex, iconName, groups, tree }

    // Tolerant decode: a v2 blob may omit `groups`; a v1 blob omits `tree`. Neither
    // should fail the whole persisted-state decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "默认 Space"
        isBrowsing = try c.decodeIfPresent(Bool.self, forKey: .isBrowsing) ?? false
        tabs = try c.decodeIfPresent([PersistedTab].self, forKey: .tabs) ?? []
        activeIndex = try c.decodeIfPresent(Int.self, forKey: .activeIndex) ?? 0
        iconName = try c.decodeIfPresent(String.self, forKey: .iconName)
        groups = try c.decodeIfPresent([WorkspaceGroupSnapshot].self, forKey: .groups) ?? []
        tree = try c.decodeIfPresent(WorkspaceTreeSnapshot.self, forKey: .tree)
    }
}


/// A launch-to-launch snapshot of the user's place: the browse category + whether
/// we're browsing vs reading, the open document tabs + the active one, plus the
/// global browse controls. `browseMode` is a raw string so MarpleKit stays agnostic
/// of the app target's `BrowseMode` enum.
public struct PersistedState: Codable, Sendable, Equatable {
    public var browsePane: Pane
    public var isBrowsing: Bool
    public var tabs: [PersistedTab]
    public var activeIndex: Int
    public var sortClauses: [SortClause]
    public var filterClauses: [FilterClause]
    public var filterMatch: FilterMatch
    public var browseMode: String
    public var currentSpace: PersistedWorkspaceSpace?
    public var spaces: [PersistedWorkspaceSpace]?
    public var activeSpaceID: UUID?
    /// Last-session sidebar counts per `EntryType`. Restored at boot so the
    /// type list shows stale-but-plausible numbers instead of all-zeros during
    /// the bootstrap window; replaced with live values once the first
    /// `loadIndex` publishes. Optional for backward compat with state blobs
    /// that predate this field.
    public var counts: [EntryType: Int]?

    public init(browsePane: Pane, isBrowsing: Bool, tabs: [PersistedTab], activeIndex: Int,
                sortClauses: [SortClause], filterClauses: [FilterClause],
                filterMatch: FilterMatch, browseMode: String,
                currentSpace: PersistedWorkspaceSpace? = nil,
                spaces: [PersistedWorkspaceSpace]? = nil,
                activeSpaceID: UUID? = nil,
                counts: [EntryType: Int]? = nil) {
        self.browsePane = browsePane; self.isBrowsing = isBrowsing
        self.tabs = tabs; self.activeIndex = activeIndex
        self.sortClauses = sortClauses; self.filterClauses = filterClauses
        self.filterMatch = filterMatch; self.browseMode = browseMode
        self.currentSpace = currentSpace
        self.spaces = spaces
        self.activeSpaceID = activeSpaceID
        self.counts = counts
    }

    public func makeWorkspace() -> Workspace? {
        if let spaces, !spaces.isEmpty {
            let active = activeSpaceID.flatMap { id in spaces.first { $0.id == id } } ?? spaces.first
            return active.flatMap { Self.makeWorkspace(tabs: $0.tabs, activeIndex: $0.activeIndex, space: $0) }
        }
        return Self.makeWorkspace(tabs: tabs, activeIndex: activeIndex, space: currentSpace)
    }

    public func makeSpaces() -> (spaces: [WorkspaceSpace], activeID: UUID?) {
        if let spaces, !spaces.isEmpty {
            let restored = spaces.map { space in
                WorkspaceSpace(id: space.id, name: space.name,
                               workspace: Self.makeWorkspace(tabs: space.tabs, activeIndex: space.activeIndex, space: space),
                               isBrowsing: space.isBrowsing,
                               iconName: space.iconName)
            }
            let active = activeSpaceID.flatMap { id in restored.contains { $0.id == id } ? id : nil } ?? restored.first?.id
            return (restored, active)
        }
        let id = currentSpace?.id ?? UUID()
        let name = currentSpace?.name ?? "默认 Space"
        let space = WorkspaceSpace(id: id, name: name, workspace: makeWorkspace(), isBrowsing: isBrowsing,
                                   iconName: currentSpace?.iconName)
        return ([space], id)
    }

    private static func makeWorkspace(tabs: [PersistedTab], activeIndex: Int, space: PersistedWorkspaceSpace?) -> Workspace? {
        let restoring = tabs.map {
            (location: $0.location, pinned: $0.pinned,
             customTitle: $0.customTitle,
             cachedTitle: $0.cachedTitle,
             cachedType: $0.cachedType)
        }
        if let tree = space?.tree {
            return Workspace(restoring: restoring, activeIndex: activeIndex, tree: tree)
        }
        return Workspace(restoring: restoring, activeIndex: activeIndex, groups: space?.groups ?? [])
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
