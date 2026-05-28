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

    enum CodingKeys: String, CodingKey {
        case location, pinned, customTitle, cachedTitle, cachedType
    }

    /// Decode with QUA-119 legacy sanitization: a pre-QUA-119 persisted blob
    /// may carry long-form values (`paper-analysis` etc.) for `cachedType`
    /// and for the pane inside `location`. Those would decode to
    /// `EntryType.other(_)` and then mis-render in the sidebar (wrong icon
    /// or empty bucket). Drop the cached type, normalize the pane.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawLocation = try c.decode(NavLocation.self, forKey: .location)
        self.location = NavLocation.sanitizingLegacyPane(rawLocation)
        self.pinned = try c.decode(Bool.self, forKey: .pinned)
        self.customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        self.cachedTitle = try c.decodeIfPresent(String.self, forKey: .cachedTitle)
        if let raw = try c.decodeIfPresent(EntryType.self, forKey: .cachedType),
           raw.isModeled {
            self.cachedType = raw
        } else {
            self.cachedType = nil
        }
    }
}

public struct PersistedWorkspaceSpace: Codable, Sendable, Equatable {
    public var name: String
    /// Legacy (v1) flat groups. Still decoded from already-stored state; new saves
    /// leave this empty and use `tree`.
    public var groups: [WorkspaceGroupSnapshot]
    /// Recursive (v2) forest. Present in new saves; absent in legacy state.
    public var tree: WorkspaceTreeSnapshot?

    public init(name: String = "默认 Space", groups: [WorkspaceGroupSnapshot] = [],
                tree: WorkspaceTreeSnapshot? = nil) {
        self.name = name
        self.groups = groups
        self.tree = tree
    }

    enum CodingKeys: String, CodingKey { case name, groups, tree }

    // Tolerant decode: a v2 blob may omit `groups`; a v1 blob omits `tree`. Neither
    // should fail the whole persisted-state decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "默认 Space"
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
                counts: [EntryType: Int]? = nil) {
        self.browsePane = browsePane; self.isBrowsing = isBrowsing
        self.tabs = tabs; self.activeIndex = activeIndex
        self.sortClauses = sortClauses; self.filterClauses = filterClauses
        self.filterMatch = filterMatch; self.browseMode = browseMode
        self.currentSpace = currentSpace
        self.counts = counts
    }

    enum CodingKeys: String, CodingKey {
        case browsePane, isBrowsing, tabs, activeIndex
        case sortClauses, filterClauses, filterMatch, browseMode
        case currentSpace, counts
    }

    /// QUA-119 legacy sanitization. A pre-QUA-119 persisted blob holds
    /// long-form pane types and counts keys (`paper-analysis`, …) that decode
    /// into `EntryType.other(_)`. Those would render as empty sidebar buckets
    /// and inflate the count list with phantom rows. Replace a stale browse
    /// pane with the first modeled type and drop legacy keys from `counts`.
    /// Tab-level pane / cachedType cleanup happens inside `PersistedTab.init`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let rawPane = try c.decode(Pane.self, forKey: .browsePane)
        if case let .type(t) = rawPane, !t.isModeled {
            self.browsePane = .type(EntryType.modeled[0])
        } else {
            self.browsePane = rawPane
        }

        self.isBrowsing = try c.decode(Bool.self, forKey: .isBrowsing)
        self.tabs = try c.decode([PersistedTab].self, forKey: .tabs)
        self.activeIndex = try c.decode(Int.self, forKey: .activeIndex)
        self.sortClauses = try c.decode([SortClause].self, forKey: .sortClauses)
        self.filterClauses = try c.decode([FilterClause].self, forKey: .filterClauses)
        self.filterMatch = try c.decode(FilterMatch.self, forKey: .filterMatch)
        self.browseMode = try c.decode(String.self, forKey: .browseMode)
        self.currentSpace = try c.decodeIfPresent(PersistedWorkspaceSpace.self, forKey: .currentSpace)

        if let raw = try c.decodeIfPresent([EntryType: Int].self, forKey: .counts) {
            let cleaned = raw.filter { $0.key.isModeled }
            self.counts = cleaned.isEmpty ? nil : cleaned
        } else {
            self.counts = nil
        }
    }

    public func makeWorkspace() -> Workspace? {
        let restoring = tabs.map {
            (location: $0.location, pinned: $0.pinned,
             customTitle: $0.customTitle,
             cachedTitle: $0.cachedTitle,
             cachedType: $0.cachedType)
        }
        if let tree = currentSpace?.tree {
            return Workspace(restoring: restoring, activeIndex: activeIndex, tree: tree)
        }
        return Workspace(restoring: restoring, activeIndex: activeIndex, groups: currentSpace?.groups ?? [])
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
