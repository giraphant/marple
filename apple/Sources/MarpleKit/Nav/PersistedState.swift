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
    /// Stable page id (the shared ItemID for pinned pages). Absent in state saved
    /// before multi-window; restore then assigns one, kept from the next save on.
    public var id: UUID?
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
    public init(id: UUID? = nil, location: NavLocation, pinned: Bool,
                customTitle: String? = nil,
                cachedTitle: String? = nil,
                cachedType: EntryType? = nil) {
        self.id = id
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
    /// Archived Spaces (QUA-216) are hidden from the switcher but kept here so they
    /// survive relaunch and can be restored from Settings. Absent in legacy blobs.
    public var isArchived: Bool
    /// Legacy (v1) flat groups. Still decoded from already-stored state; new saves
    /// leave this empty and use `tree`.
    public var groups: [WorkspaceGroupSnapshot]
    /// Recursive (v2) forest. Present in new saves; absent in legacy state.
    public var tree: WorkspaceTreeSnapshot?

    public init(id: UUID = UUID(), name: String = "默认 Space", isBrowsing: Bool = false,
                tabs: [PersistedTab] = [], activeIndex: Int = 0,
                iconName: String? = nil, isArchived: Bool = false,
                groups: [WorkspaceGroupSnapshot] = [], tree: WorkspaceTreeSnapshot? = nil) {
        self.id = id
        self.name = name
        self.isBrowsing = isBrowsing
        self.tabs = tabs
        self.activeIndex = activeIndex
        self.iconName = iconName
        self.isArchived = isArchived
        self.groups = groups
        self.tree = tree
    }

    enum CodingKeys: String, CodingKey { case id, name, isBrowsing, tabs, activeIndex, iconName, isArchived, groups, tree }

    // Tolerant decode: a v2 blob may omit `groups`; a v1 blob omits `tree`. Neither
    // should fail the whole persisted-state decode. An unreadable tab is skipped and
    // the index references to the remaining tabs are re-pointed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "默认 Space"
        isBrowsing = try c.decodeIfPresent(Bool.self, forKey: .isBrowsing) ?? false
        let decodedTabs = c.lossyArray(PersistedTab.self, forKey: .tabs, in: decoder)
        tabs = decodedTabs?.values ?? []
        activeIndex = try c.decodeIfPresent(Int.self, forKey: .activeIndex) ?? 0
        iconName = try c.decodeIfPresent(String.self, forKey: .iconName)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        groups = c.lossyArray(WorkspaceGroupSnapshot.self, forKey: .groups, in: decoder)?.values ?? []
        tree = c.lenient(WorkspaceTreeSnapshot.self, forKey: .tree, in: decoder)
        if let decodedTabs, decodedTabs.droppedAny {
            let map = decodedTabs.indexMap
            activeIndex = map[activeIndex] ?? 0
            for i in groups.indices { groups[i].tabIndices = groups[i].tabIndices.compactMap { map[$0] } }
            tree = tree?.remappingTabs(map)
        }
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
    /// Saved smart-folder views (QUA-127). App state like workspaces/tabs —
    /// UserDefaults, never SQLite. Optional so blobs predating the field decode.
    public var savedViews: [SavedView]?
    /// Open windows, front first (multi-window). nil in state saved before
    /// multi-window: `restoredSession()` then migrates the fields above into one
    /// window. When present, `spaces` hold only the shared part (pinned pages +
    /// folders); temporary pages and selection live in each window's session.
    public var windows: [PersistedWindow]?
    /// The last window the user closed, for reopening from the Dock.
    public var recentlyClosedWindow: PersistedWindow?

    public init(browsePane: Pane, isBrowsing: Bool, tabs: [PersistedTab], activeIndex: Int,
                sortClauses: [SortClause], filterClauses: [FilterClause],
                filterMatch: FilterMatch, browseMode: String,
                currentSpace: PersistedWorkspaceSpace? = nil,
                spaces: [PersistedWorkspaceSpace]? = nil,
                activeSpaceID: UUID? = nil,
                counts: [EntryType: Int]? = nil,
                savedViews: [SavedView]? = nil) {
        self.browsePane = browsePane; self.isBrowsing = isBrowsing
        self.tabs = tabs; self.activeIndex = activeIndex
        self.sortClauses = sortClauses; self.filterClauses = filterClauses
        self.filterMatch = filterMatch; self.browseMode = browseMode
        self.currentSpace = currentSpace
        self.spaces = spaces
        self.activeSpaceID = activeSpaceID
        self.counts = counts
        self.savedViews = savedViews
    }

    private enum CodingKeys: String, CodingKey {
        case browsePane, isBrowsing, tabs, activeIndex, sortClauses, filterClauses,
             filterMatch, browseMode, currentSpace, spaces, activeSpaceID, counts, savedViews,
             windows, recentlyClosedWindow
    }

    // Every field degrades on its own (see StateDecoding.swift): another build's
    // schema must never cost the user their Spaces.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browsePane = c.lenient(Pane.self, forKey: .browsePane, in: decoder) ?? .type(.paper)
        isBrowsing = c.lenient(Bool.self, forKey: .isBrowsing, in: decoder) ?? true
        let decodedTabs = c.lossyArray(PersistedTab.self, forKey: .tabs, in: decoder)
        tabs = decodedTabs?.values ?? []
        let savedIndex = c.lenient(Int.self, forKey: .activeIndex, in: decoder) ?? 0
        activeIndex = decodedTabs?.indexMap[savedIndex] ?? 0
        sortClauses = c.lossyArray(SortClause.self, forKey: .sortClauses, in: decoder)?.values ?? []
        filterClauses = c.lossyArray(FilterClause.self, forKey: .filterClauses, in: decoder)?.values ?? []
        filterMatch = c.lenient(FilterMatch.self, forKey: .filterMatch, in: decoder) ?? .all
        browseMode = c.lenient(String.self, forKey: .browseMode, in: decoder) ?? ""
        currentSpace = c.lenient(PersistedWorkspaceSpace.self, forKey: .currentSpace, in: decoder)
        spaces = c.lossyArray(PersistedWorkspaceSpace.self, forKey: .spaces, in: decoder)?.values
        activeSpaceID = c.lenient(UUID.self, forKey: .activeSpaceID, in: decoder)
        counts = c.lenient([EntryType: Int].self, forKey: .counts, in: decoder)
        savedViews = c.lossyArray(SavedView.self, forKey: .savedViews, in: decoder)?.values
        windows = c.lossyArray(PersistedWindow.self, forKey: .windows, in: decoder)?.values
        recentlyClosedWindow = c.lenient(PersistedWindow.self, forKey: .recentlyClosedWindow, in: decoder)
    }

    public func makeWorkspace() -> Workspace? {
        var seenIDs = Set<UUID>()
        if let spaces, !spaces.isEmpty {
            let active = activeSpaceID.flatMap { id in spaces.first { $0.id == id } } ?? spaces.first
            return active.flatMap {
                Self.makeWorkspace(tabs: $0.tabs, activeIndex: $0.activeIndex, space: $0, seenIDs: &seenIDs)
            }
        }
        return Self.makeWorkspace(tabs: tabs, activeIndex: activeIndex, space: currentSpace, seenIDs: &seenIDs)
    }

    public func makeSpaces() -> (spaces: [WorkspaceSpace], activeID: UUID?) {
        // Page ids must be unique across Spaces (pages move between them); a
        // repeated or missing id gets a fresh one.
        var seenIDs = Set<UUID>()
        if let spaces, !spaces.isEmpty {
            let restored = spaces.map { space in
                let workspace = Self.makeWorkspace(tabs: space.tabs, activeIndex: space.activeIndex,
                                                   space: space, seenIDs: &seenIDs)
                return WorkspaceSpace(id: space.id, name: space.name,
                                      workspace: workspace,
                                      isBrowsing: workspace?.tabs.isEmpty != false ? true : space.isBrowsing,
                                      iconName: space.iconName,
                                      isArchived: space.isArchived)
            }
            // Never restore an archived Space as active — it isn't shown in the switcher.
            let active = activeSpaceID.flatMap { id in
                restored.first { $0.id == id && !$0.isArchived }?.id
            } ?? restored.first { !$0.isArchived }?.id ?? restored.first?.id
            return (restored, active)
        }
        let id = currentSpace?.id ?? UUID()
        let name = currentSpace?.name ?? "默认 Space"
        let workspace = Self.makeWorkspace(tabs: tabs, activeIndex: activeIndex, space: currentSpace,
                                           seenIDs: &seenIDs)
        let space = WorkspaceSpace(id: id, name: name, workspace: workspace, isBrowsing: isBrowsing,
                                   iconName: currentSpace?.iconName)
        return ([space], id)
    }

    private static func makeWorkspace(tabs: [PersistedTab], activeIndex: Int, space: PersistedWorkspaceSpace?,
                                      seenIDs: inout Set<UUID>) -> Workspace? {
        let restoring = tabs.map { tab -> NavTab in
            let id = tab.id.flatMap { seenIDs.contains($0) ? nil : $0 } ?? UUID()
            seenIDs.insert(id)
            return NavTab(id: id, location: tab.location, pinned: tab.pinned,
                          customTitle: tab.customTitle,
                          cachedTitle: tab.cachedTitle,
                          cachedType: tab.cachedType)
        }
        if let tree = space?.tree {
            return Workspace(restoringTabs: restoring, activeIndex: activeIndex, tree: tree)
        }
        return Workspace(restoringTabs: restoring, activeIndex: activeIndex, groups: space?.groups ?? [])
    }
}

/// The outcome of reading saved state. "Nothing saved yet" and "saved but
/// unreadable" must not look alike: the second used to be overwritten silently.
public struct StateLoadResult: Sendable {
    public var state: PersistedState?
    /// True when some or all of the saved state could not be read.
    public var hadErrors: Bool
    /// Copy of the original bytes, written before anything could overwrite them.
    public var backupURL: URL?
    /// False when saving would replace state this build could not read at all, or
    /// when the backup failed — the caller must then not save this session.
    public var allowsSaving: Bool

    public init(state: PersistedState?, hadErrors: Bool = false,
                backupURL: URL? = nil, allowsSaving: Bool = true) {
        self.state = state
        self.hadErrors = hadErrors
        self.backupURL = backupURL
        self.allowsSaving = allowsSaving
    }
}

/// Where persisted state lives. App uses UserDefaults; tests can substitute.
public protocol StateStore: Sendable {
    func load() -> PersistedState?
    func loadResult() -> StateLoadResult
    func save(_ state: PersistedState)
}

public extension StateStore {
    func loadResult() -> StateLoadResult { StateLoadResult(state: load()) }
}

public struct UserDefaultsStateStore: StateStore, @unchecked Sendable {
    public static let defaultKey = "marple.persistedState"

    private let defaults: UserDefaults
    private let key: String
    private let backupDirectory: URL

    public init(defaults: UserDefaults = .standard, key: String = Self.defaultKey,
                backupDirectory: URL? = nil) {
        self.defaults = defaults; self.key = key
        self.backupDirectory = backupDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Marple/StateBackups", isDirectory: true)
    }

    public func load() -> PersistedState? { loadResult().state }

    public func loadResult() -> StateLoadResult {
        guard let data = defaults.data(forKey: key) else { return StateLoadResult(state: nil) }
        let log = StateDecodeLog()
        let decoder = JSONDecoder()
        decoder.userInfo[.stateDecodeLog] = log
        var state: PersistedState?
        do { state = try decoder.decode(PersistedState.self, from: data) } catch {
            NSLog("[marple] persisted state unreadable: %@", String(describing: error))
            log.record(error)
        }
        guard !log.errors.isEmpty else { return StateLoadResult(state: state) }
        do {
            let url = try backUp(data)
            return StateLoadResult(state: state, hadErrors: true, backupURL: url,
                                   allowsSaving: state != nil)
        } catch {
            NSLog("[marple] persisted state backup failed: %@", String(describing: error))
            return StateLoadResult(state: state, hadErrors: true, allowsSaving: false)
        }
    }

    public func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    private func backUp(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = backupDirectory.appendingPathComponent(
            "persistedState-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}
