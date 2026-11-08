import Foundation

/// A pinned page's current place in one window, saved only when it differs from
/// the page's anchor (the anchor itself lives in the shared definition).
public struct PersistedPinnedLocation: Codable, Sendable, Equatable {
    public var id: UUID
    public var location: NavLocation

    public init(id: UUID, location: NavLocation) {
        self.id = id
        self.location = location
    }
}

/// One window's reading state in one Space: browse/read mode, selection, its
/// temporary pages, where its pinned pages are, and which folders it collapsed.
public struct PersistedSpaceSession: Codable, Sendable, Equatable {
    public var spaceID: UUID
    public var isBrowsing: Bool
    public var activeTabID: UUID?
    public var temporaryTabs: [PersistedTab]
    public var pinnedLocations: [PersistedPinnedLocation]
    public var collapsedGroupIDs: [UUID]

    public init(spaceID: UUID, isBrowsing: Bool, activeTabID: UUID?,
                temporaryTabs: [PersistedTab], pinnedLocations: [PersistedPinnedLocation],
                collapsedGroupIDs: [UUID]) {
        self.spaceID = spaceID
        self.isBrowsing = isBrowsing
        self.activeTabID = activeTabID
        self.temporaryTabs = temporaryTabs
        self.pinnedLocations = pinnedLocations
        self.collapsedGroupIDs = collapsedGroupIDs
    }

    private enum CodingKeys: String, CodingKey {
        case spaceID, isBrowsing, activeTabID, temporaryTabs, pinnedLocations, collapsedGroupIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaceID = try c.decode(UUID.self, forKey: .spaceID)
        isBrowsing = c.lenient(Bool.self, forKey: .isBrowsing, in: decoder) ?? true
        activeTabID = c.lenient(UUID.self, forKey: .activeTabID, in: decoder)
        temporaryTabs = c.lossyArray(PersistedTab.self, forKey: .temporaryTabs, in: decoder)?.values ?? []
        pinnedLocations = c.lossyArray(PersistedPinnedLocation.self, forKey: .pinnedLocations, in: decoder)?.values ?? []
        collapsedGroupIDs = c.lossyArray(UUID.self, forKey: .collapsedGroupIDs, in: decoder)?.values ?? []
    }
}

/// One window: its place on screen, its browse controls, and its per-Space sessions.
public struct PersistedWindow: Codable, Sendable, Equatable {
    public var id: UUID
    /// `NSWindow.frameDescriptor`; nil lets the app pick a default frame.
    public var frame: String?
    public var activeSpaceID: UUID?
    public var browsePane: Pane
    public var sortClauses: [SortClause]
    public var filterClauses: [FilterClause]
    public var filterMatch: FilterMatch
    public var browseMode: String
    public var spaces: [PersistedSpaceSession]

    public init(id: UUID, frame: String? = nil, activeSpaceID: UUID?, browsePane: Pane,
                sortClauses: [SortClause], filterClauses: [FilterClause],
                filterMatch: FilterMatch, browseMode: String,
                spaces: [PersistedSpaceSession]) {
        self.id = id
        self.frame = frame
        self.activeSpaceID = activeSpaceID
        self.browsePane = browsePane
        self.sortClauses = sortClauses
        self.filterClauses = filterClauses
        self.filterMatch = filterMatch
        self.browseMode = browseMode
        self.spaces = spaces
    }

    private enum CodingKeys: String, CodingKey {
        case id, frame, activeSpaceID, browsePane, sortClauses, filterClauses,
             filterMatch, browseMode, spaces
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(UUID.self, forKey: .id, in: decoder) ?? UUID()
        frame = c.lenient(String.self, forKey: .frame, in: decoder)
        activeSpaceID = c.lenient(UUID.self, forKey: .activeSpaceID, in: decoder)
        browsePane = c.lenient(Pane.self, forKey: .browsePane, in: decoder) ?? .type(.paper)
        sortClauses = c.lossyArray(SortClause.self, forKey: .sortClauses, in: decoder)?.values ?? []
        filterClauses = c.lossyArray(FilterClause.self, forKey: .filterClauses, in: decoder)?.values ?? []
        filterMatch = c.lenient(FilterMatch.self, forKey: .filterMatch, in: decoder) ?? .all
        browseMode = c.lenient(String.self, forKey: .browseMode, in: decoder) ?? ""
        spaces = c.lossyArray(PersistedSpaceSession.self, forKey: .spaces, in: decoder)?.values ?? []
    }
}

public extension PersistedSpaceSession {
    /// Capture one window's Space. Cached titles/types come from `cache` (the live
    /// index), falling back to what the tab already carried.
    init(space: WorkspaceSpace, cache: (NavLocation) -> (title: String?, type: EntryType?)) {
        let tabs = space.workspace?.tabs ?? []
        self.init(
            spaceID: space.id,
            isBrowsing: tabs.isEmpty ? true : space.isBrowsing,
            activeTabID: space.workspace?.activeID,
            temporaryTabs: tabs.filter { !$0.pinned }.map { tab in
                let cached = cache(tab.location)
                return PersistedTab(id: tab.id, location: tab.location, pinned: false,
                                    customTitle: tab.customTitle,
                                    cachedTitle: cached.title ?? tab.cachedTitle,
                                    cachedType: cached.type ?? tab.cachedType)
            },
            pinnedLocations: tabs.compactMap { tab in
                guard tab.pinned, tab.location != tab.identityLocation else { return nil }
                return PersistedPinnedLocation(id: tab.id, location: tab.location)
            },
            collapsedGroupIDs: space.workspace?.collapsedGroupIDs.sorted { $0.uuidString < $1.uuidString } ?? [])
    }
}

/// One window rebuilt from disk: every Space as this window last saw it.
public struct RestoredWindow: Sendable {
    public var id: UUID
    public var frame: String?
    public var spaces: [WorkspaceSpace]
    public var activeSpaceID: UUID?
    public var browsePane: Pane
    public var sortClauses: [SortClause]
    public var filterClauses: [FilterClause]
    public var filterMatch: FilterMatch
    public var browseMode: String

    public init(id: UUID, frame: String? = nil, spaces: [WorkspaceSpace], activeSpaceID: UUID?,
                browsePane: Pane, sortClauses: [SortClause], filterClauses: [FilterClause],
                filterMatch: FilterMatch, browseMode: String) {
        self.id = id
        self.frame = frame
        self.spaces = spaces
        self.activeSpaceID = activeSpaceID
        self.browsePane = browsePane
        self.sortClauses = sortClauses
        self.filterClauses = filterClauses
        self.filterMatch = filterMatch
        self.browseMode = browseMode
    }
}

/// Everything restored at launch: the shared Space definitions plus each window.
public struct RestoredSession: Sendable {
    public var definitions: [SpaceDefinition]
    public var windows: [RestoredWindow]
    public var recentlyClosedWindow: RestoredWindow?
}

public extension PersistedState {
    /// Rebuild the shared definitions and every saved window. State written before
    /// multi-window has no `windows`; it migrates into a single window holding the
    /// old selection, temporary pages, folder collapse and browse controls.
    func restoredSession() -> RestoredSession {
        let shared = makeSpaces()
        let definitions = shared.spaces.map(\.definition)
        guard let windows else {
            let window = RestoredWindow(
                id: UUID(), frame: nil, spaces: shared.spaces, activeSpaceID: shared.activeID,
                browsePane: browsePane, sortClauses: sortClauses, filterClauses: filterClauses,
                filterMatch: filterMatch, browseMode: browseMode)
            return RestoredSession(definitions: definitions, windows: [window],
                                   recentlyClosedWindow: nil)
        }
        let collapsedDefaults = Dictionary(uniqueKeysWithValues: shared.spaces.map {
            ($0.id, $0.workspace?.collapsedGroupIDs ?? [])
        })
        func restore(_ window: PersistedWindow) -> RestoredWindow {
            window.restored(over: definitions, collapsedDefaults: collapsedDefaults)
        }
        var seen = Set<UUID>()
        var restored = windows.filter { seen.insert($0.id).inserted }.map(restore)
        // Quit with every window closed: reopen the last one rather than nothing.
        if restored.isEmpty {
            restored = [recentlyClosedWindow.map(restore) ?? RestoredWindow(
                id: UUID(), spaces: definitions.map { WorkspaceSpace(definition: $0) },
                activeSpaceID: definitions.first { !$0.isArchived }?.id,
                browsePane: browsePane, sortClauses: sortClauses, filterClauses: filterClauses,
                filterMatch: filterMatch, browseMode: browseMode)]
        }
        return RestoredSession(definitions: definitions, windows: restored,
                               recentlyClosedWindow: recentlyClosedWindow.map(restore))
    }

    /// The saved form: shared definitions once, each window's session separately.
    /// The legacy top-level fields and each shared Space's selection/collapse come
    /// from `windows.first` (the front window) so an older build still opens.
    init(definitions: [SpaceDefinition], windows: [PersistedWindow],
         recentlyClosedWindow: PersistedWindow? = nil,
         counts: [EntryType: Int]?, savedViews: [SavedView]?,
         cache: (NavLocation) -> (title: String?, type: EntryType?)) {
        let front = windows.first
        let frontSessions = Dictionary((front?.spaces ?? []).map { ($0.spaceID, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let spaces = definitions.map { definition -> PersistedWorkspaceSpace in
            let items = definition.items
            let indexByID = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) },
                                       uniquingKeysWith: { first, _ in first })
            let session = frontSessions[definition.id]
            let collapsed = Set(session?.collapsedGroupIDs ?? [])
            func convert(_ nodes: [SpaceDefinition.Node]) -> [WorkspaceTreeSnapshot.Node] {
                nodes.compactMap { node in
                    switch node {
                    case .item(let item):
                        return indexByID[item.id].map(WorkspaceTreeSnapshot.Node.tab)
                    case .group(let group):
                        return .group(.init(id: group.id, name: group.name,
                                            isCollapsed: collapsed.contains(group.id),
                                            children: convert(group.children)))
                    }
                }
            }
            let activeIndex = session?.activeTabID.flatMap { indexByID[$0] }
            return PersistedWorkspaceSpace(
                id: definition.id, name: definition.name,
                isBrowsing: activeIndex == nil ? true : (session?.isBrowsing ?? true),
                tabs: items.map { item in
                    let cached = cache(item.home)
                    return PersistedTab(id: item.id, location: item.home, pinned: true,
                                        customTitle: item.customTitle,
                                        cachedTitle: cached.title ?? item.cachedTitle,
                                        cachedType: cached.type ?? item.cachedType)
                },
                activeIndex: activeIndex ?? 0,
                iconName: definition.iconName, isArchived: definition.isArchived,
                tree: WorkspaceTreeSnapshot(roots: convert(definition.roots)))
        }
        let active = front?.activeSpaceID.flatMap { id in spaces.first { $0.id == id } } ?? spaces.first
        self.init(browsePane: front?.browsePane ?? .type(.paper),
                  isBrowsing: active?.isBrowsing ?? true,
                  tabs: active?.tabs ?? [], activeIndex: active?.activeIndex ?? 0,
                  sortClauses: front?.sortClauses ?? [],
                  filterClauses: front?.filterClauses ?? [],
                  filterMatch: front?.filterMatch ?? .all,
                  browseMode: front?.browseMode ?? "",
                  currentSpace: active, spaces: spaces, activeSpaceID: active?.id,
                  counts: counts, savedViews: savedViews)
        self.windows = windows
        self.recentlyClosedWindow = recentlyClosedWindow
    }
}

public extension PersistedWindow {
    /// This window laid over the current shared definitions. A Space the window
    /// never saved a session for opens at its anchors; `collapsedDefaults` gives
    /// such Spaces their folder collapse.
    func restored(over definitions: [SpaceDefinition],
                  collapsedDefaults: [UUID: Set<UUID>] = [:]) -> RestoredWindow {
        let sessions = Dictionary(spaces.map { ($0.spaceID, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let restoredSpaces = definitions.map { definition -> WorkspaceSpace in
            guard let session = sessions[definition.id] else {
                return WorkspaceSpace(definition: definition,
                                      collapsedGroupIDs: collapsedDefaults[definition.id] ?? [])
            }
            let workspace = Workspace(
                shared: definition.roots,
                collapsed: Set(session.collapsedGroupIDs),
                pinnedLocations: Dictionary(session.pinnedLocations.map { ($0.id, $0.location) },
                                            uniquingKeysWith: { first, _ in first }),
                temporary: session.temporaryTabs.map { tab in
                    NavTab(id: tab.id ?? UUID(), location: tab.location,
                           customTitle: tab.customTitle, cachedTitle: tab.cachedTitle,
                           cachedType: tab.cachedType)
                },
                activeID: session.activeTabID)
            return WorkspaceSpace(id: definition.id, name: definition.name,
                                  workspace: workspace.isEmpty ? nil : workspace,
                                  isBrowsing: workspace.tabs.isEmpty ? true : session.isBrowsing,
                                  iconName: definition.iconName,
                                  isArchived: definition.isArchived)
        }
        let active = activeSpaceID.flatMap { id in
            restoredSpaces.first { $0.id == id && !$0.isArchived }?.id
        } ?? restoredSpaces.first { !$0.isArchived }?.id ?? restoredSpaces.first?.id
        return RestoredWindow(id: id, frame: frame, spaces: restoredSpaces, activeSpaceID: active,
                              browsePane: browsePane, sortClauses: sortClauses,
                              filterClauses: filterClauses, filterMatch: filterMatch,
                              browseMode: browseMode)
    }
}
