import Foundation

/// Constants shared by macOS and iOS for CloudKit Private Database sync.
public enum CloudSyncConstants {
    public static let containerIdentifier = "iCloud.com.quasifish.marple"
    public static let zoneName = "MarpleSync"
    /// Single generic record type so adding fields to Swift Codable payloads
    /// never requires CloudKit Dashboard schema changes.
    public static let recordType = "MarpleSyncRecord"
    public static let payloadField = "payload"
    public static let schemaVersionField = "schemaVersion"
    public static let currentSchemaVersion = 1

    public static let spaceRecordPrefix = "space-"
    public static let libraryMetaRecordName = "library-meta"
    public static let settingsRecordName = "settings"
    public static let activeSessionRecordName = "active-session"
}

/// A portable temporary tab inside a synced Space. Strips `listContext` (transient
/// search queries) and derived `cachedTitle`/`cachedType`.
public struct SyncedTemporaryTab: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var pane: Pane
    public var openPath: String?
    public var customTitle: String?

    public init(id: UUID, pane: Pane, openPath: String? = nil, customTitle: String? = nil) {
        self.id = id
        self.pane = pane
        self.openPath = openPath
        self.customTitle = customTitle
    }

    public init(tab: PersistedTab) {
        self.id = tab.id ?? UUID()
        self.pane = tab.location.pane
        self.openPath = tab.location.openPath
        self.customTitle = tab.customTitle
    }

    public var location: NavLocation {
        NavLocation(pane: pane, openPath: openPath, listContext: nil)
    }

    public var persistedTab: PersistedTab {
        PersistedTab(id: id, location: location, pinned: false, customTitle: customTitle)
    }
}

/// One synced Space (`space-<uuid>` record): its shared pinned forest (`SpaceDefinition`)
/// plus its shared temporary tabs. Window-local reading state (active selection,
/// history, folder collapse) never enters CloudKit here.
public struct SyncedSpacePayload: Codable, Hashable, Sendable, Identifiable {
    public var definition: SpaceDefinition
    public var temporaryTabs: [SyncedTemporaryTab]

    public var id: UUID { definition.id }

    public init(definition: SpaceDefinition, temporaryTabs: [SyncedTemporaryTab] = []) {
        self.definition = Self.sanitized(definition)
        self.temporaryTabs = temporaryTabs.map(Self.sanitized)
    }

    /// Strip transient `listContext` and derived cache fields from every pinned item
    /// so equality comparisons and cloud payloads stay minimal and deterministic.
    private static func sanitized(_ def: SpaceDefinition) -> SpaceDefinition {
        func clean(_ nodes: [SpaceDefinition.Node]) -> [SpaceDefinition.Node] {
            nodes.map { node in
                switch node {
                case .item(var item):
                    item.home = NavLocation(pane: item.home.pane, openPath: item.home.openPath, listContext: nil)
                    item.cachedTitle = nil
                    item.cachedType = nil
                    return .item(item)
                case .group(var group):
                    group.children = clean(group.children)
                    return .group(group)
                }
            }
        }
        return SpaceDefinition(id: def.id, name: def.name, iconName: def.iconName,
                               isArchived: def.isArchived, roots: clean(def.roots))
    }

    private static func sanitized(_ tab: SyncedTemporaryTab) -> SyncedTemporaryTab {
        SyncedTemporaryTab(id: tab.id, pane: tab.pane, openPath: tab.openPath, customTitle: tab.customTitle)
    }

    /// Reconstruct a `WorkspaceSpace` containing both the pinned forest and the
    /// shared temporary tabs (starting at their synced locations, all groups expanded).
    public func makeWorkspaceSpace() -> WorkspaceSpace {
        let workspace = Workspace(
            shared: definition.roots,
            collapsed: [],
            pinnedLocations: [:],
            temporary: temporaryTabs.map {
                NavTab(id: $0.id, location: $0.location, pinned: false, customTitle: $0.customTitle)
            },
            activeID: nil
        )
        return WorkspaceSpace(
            id: definition.id,
            name: definition.name,
            workspace: workspace.isEmpty ? nil : workspace,
            isBrowsing: true,
            iconName: definition.iconName,
            isArchived: definition.isArchived
        )
    }

    /// Clone this Space as a standalone conflict copy with brand-new UUIDs for
    /// the Space and every pinned item, group, and temporary tab (preserving the
    /// invariant that page/group IDs are globally unique across Spaces).
    public func asConflictCopy(suffix: String = "（冲突副本）") -> SyncedSpacePayload {
        func rekey(_ nodes: [SpaceDefinition.Node]) -> [SpaceDefinition.Node] {
            nodes.map { node in
                switch node {
                case .item(let item):
                    return .item(SpaceDefinition.Item(
                        id: UUID(), home: item.home, customTitle: item.customTitle
                    ))
                case .group(let group):
                    return .group(SpaceDefinition.Group(
                        id: UUID(), name: group.name, children: rekey(group.children)
                    ))
                }
            }
        }
        let copyDef = SpaceDefinition(
            id: UUID(),
            name: definition.name + suffix,
            iconName: definition.iconName,
            isArchived: definition.isArchived,
            roots: rekey(definition.roots)
        )
        let copyTemps = temporaryTabs.map {
            SyncedTemporaryTab(id: UUID(), pane: $0.pane, openPath: $0.openPath, customTitle: $0.customTitle)
        }
        return SyncedSpacePayload(definition: copyDef, temporaryTabs: copyTemps)
    }
}

/// Library-level sidebar metadata (`library-meta` record): Space switcher order,
/// saved smart views, sidebar type order, and hidden types.
public struct SyncedLibraryMeta: Codable, Equatable, Sendable {
    public var spaceOrder: [UUID]
    public var savedViews: [SavedView]
    public var typeOrder: [EntryType]
    public var hiddenTypes: [EntryType]

    public init(spaceOrder: [UUID], savedViews: [SavedView],
                typeOrder: [EntryType], hiddenTypes: [EntryType]) {
        self.spaceOrder = spaceOrder
        self.savedViews = savedViews
        self.typeOrder = typeOrder
        self.hiddenTypes = hiddenTypes.sorted { $0.rawValue < $1.rawValue }
    }
}

/// Strict 11-key portable settings whitelist (`settings` record).
/// Explicitly excludes local paths, machine services, AI commands/prompts, and secrets.
public struct SyncedSettings: Codable, Hashable, Sendable {
    public var balancedTermExpansion: Bool
    public var deepTermExpansion: Bool
    public var termExpansionDepth: Int
    public var theme: String
    public var readingFontFamily: String
    public var readingFontSize: Double
    public var readingLineHeight: Double
    public var readingLetterSpacing: Double
    public var citationFormat: String
    public var citationClickAction: String
    public var originalClickAction: String

    public init(
        balancedTermExpansion: Bool = false,
        deepTermExpansion: Bool = false,
        termExpansionDepth: Int = 2,
        theme: String = "system",
        readingFontFamily: String = "sans",
        readingFontSize: Double = 15,
        readingLineHeight: Double = 1.62,
        readingLetterSpacing: Double = 0.04,
        citationFormat: String = "inline-en",
        citationClickAction: String = "copyDefault",
        originalClickAction: String = "openOriginal"
    ) {
        self.balancedTermExpansion = balancedTermExpansion
        self.deepTermExpansion = deepTermExpansion
        self.termExpansionDepth = min(max(termExpansionDepth, 1), 5)
        self.theme = theme
        self.readingFontFamily = readingFontFamily
        self.readingFontSize = readingFontSize
        self.readingLineHeight = readingLineHeight
        self.readingLetterSpacing = readingLetterSpacing
        self.citationFormat = citationFormat
        self.citationClickAction = citationClickAction
        self.originalClickAction = originalClickAction
    }
}

/// High-frequency active-document indicator (`active-session` record), isolated
/// from Space records so clicking tabs never touches structural CloudKit records.
/// Consumed read-only by iOS for the subtle "you are here" mark and sync timestamp.
public struct SyncedActiveSession: Codable, Hashable, Sendable {
    public var updatedAtMs: Int64
    /// Space UUID string -> active document workspace-relative path.
    public var activePathBySpace: [String: String]

    public init(updatedAtMs: Int64, activePathBySpace: [String: String]) {
        self.updatedAtMs = updatedAtMs
        self.activePathBySpace = activePathBySpace
    }

    /// Compare only the active paths when deciding whether to push a new record.
    public func hasSamePaths(as other: SyncedActiveSession?) -> Bool {
        guard let other else { return false }
        return activePathBySpace == other.activePathBySpace
    }
}

/// Tagged union of every record stored in the `MarpleSync` CloudKit zone.
public enum CloudSyncRecord: Equatable, Sendable {
    case space(SyncedSpacePayload)
    case libraryMeta(SyncedLibraryMeta)
    case settings(SyncedSettings)
    case activeSession(SyncedActiveSession)

    public var recordName: String {
        switch self {
        case .space(let s): return CloudSyncConstants.spaceRecordPrefix + s.id.uuidString
        case .libraryMeta: return CloudSyncConstants.libraryMetaRecordName
        case .settings: return CloudSyncConstants.settingsRecordName
        case .activeSession: return CloudSyncConstants.activeSessionRecordName
        }
    }
}

/// Full materialized state of the `MarpleSync` CloudKit zone.
public struct CloudSyncSnapshot: Codable, Equatable, Sendable {
    public var spacesByID: [UUID: SyncedSpacePayload]
    public var libraryMeta: SyncedLibraryMeta?
    public var settings: SyncedSettings?
    public var activeSession: SyncedActiveSession?

    public init(spacesByID: [UUID: SyncedSpacePayload] = [:],
                libraryMeta: SyncedLibraryMeta? = nil,
                settings: SyncedSettings? = nil,
                activeSession: SyncedActiveSession? = nil) {
        self.spacesByID = spacesByID
        self.libraryMeta = libraryMeta
        self.settings = settings
        self.activeSession = activeSession
    }

    public var isEmpty: Bool {
        spacesByID.isEmpty && libraryMeta == nil && settings == nil && activeSession == nil
    }

    /// Spaces in switcher order: follows `libraryMeta.spaceOrder`, then appends
    /// any space records not yet listed in `spaceOrder` deterministically by UUID.
    public func orderedSpaces() -> [SyncedSpacePayload] {
        var result: [SyncedSpacePayload] = []
        var seen = Set<UUID>()
        for id in libraryMeta?.spaceOrder ?? [] {
            if let space = spacesByID[id], seen.insert(id).inserted {
                result.append(space)
            }
        }
        let remainder = spacesByID.values
            .filter { !seen.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        result.append(contentsOf: remainder)
        return result
    }

    public mutating func apply(_ record: CloudSyncRecord) {
        switch record {
        case .space(let s): spacesByID[s.id] = s
        case .libraryMeta(let m): libraryMeta = m
        case .settings(let s): settings = s
        case .activeSession(let a): activeSession = a
        }
    }

    public mutating func remove(recordName: String) {
        if recordName.hasPrefix(CloudSyncConstants.spaceRecordPrefix) {
            let suffix = String(recordName.dropFirst(CloudSyncConstants.spaceRecordPrefix.count))
            if let id = UUID(uuidString: suffix) {
                spacesByID.removeValue(forKey: id)
            }
        } else if recordName == CloudSyncConstants.libraryMetaRecordName {
            libraryMeta = nil
        } else if recordName == CloudSyncConstants.settingsRecordName {
            settings = nil
        } else if recordName == CloudSyncConstants.activeSessionRecordName {
            activeSession = nil
        }
    }

    /// Compute the minimal set of record saves and deletions needed to move
    /// from `previous` to `self`.
    public func diff(from previous: CloudSyncSnapshot) -> (saves: [CloudSyncRecord], deletions: [String]) {
        var saves: [CloudSyncRecord] = []
        var deletions: [String] = []

        for (id, space) in spacesByID {
            if previous.spacesByID[id] != space {
                saves.append(.space(space))
            }
        }
        for id in previous.spacesByID.keys where spacesByID[id] == nil {
            deletions.append(CloudSyncConstants.spaceRecordPrefix + id.uuidString)
        }
        if let meta = libraryMeta, previous.libraryMeta != meta {
            saves.append(.libraryMeta(meta))
        }
        if let settings, previous.settings != settings {
            saves.append(.settings(settings))
        }
        if let active = activeSession, !active.hasSamePaths(as: previous.activeSession) {
            saves.append(.activeSession(active))
        }
        return (saves, deletions)
    }

    /// Losslessly merge `local` and `remote` snapshots (used for "合并保留两份"):
    /// keeps all local Spaces in order, appends remote Spaces with distinct IDs,
    /// and saves any diverged same-ID remote Space as a conflict copy with fresh
    /// UUIDs. Unions `savedViews` by ID and keeps local `typeOrder`/`hiddenTypes`/`settings`.
    public static func merged(local: CloudSyncSnapshot, remote: CloudSyncSnapshot) -> CloudSyncSnapshot {
        var mergedSpaces = local.spacesByID
        var order = local.orderedSpaces().map(\.id)
        var seenSpaceIDs = Set(order)

        for remoteSpace in remote.orderedSpaces() {
            if let existing = mergedSpaces[remoteSpace.id] {
                if existing != remoteSpace {
                    let copy = remoteSpace.asConflictCopy()
                    mergedSpaces[copy.id] = copy
                    order.append(copy.id)
                    seenSpaceIDs.insert(copy.id)
                }
            } else {
                mergedSpaces[remoteSpace.id] = remoteSpace
                if seenSpaceIDs.insert(remoteSpace.id).inserted {
                    order.append(remoteSpace.id)
                }
            }
        }

        let localViews = local.libraryMeta?.savedViews ?? []
        var mergedViews = localViews
        var seenViewIDs = Set(localViews.map(\.id))
        for view in remote.libraryMeta?.savedViews ?? [] where seenViewIDs.insert(view.id).inserted {
            mergedViews.append(view)
        }

        let typeOrder = local.libraryMeta?.typeOrder ?? remote.libraryMeta?.typeOrder ?? EntryType.modeled
        let hiddenTypes = local.libraryMeta?.hiddenTypes ?? remote.libraryMeta?.hiddenTypes ?? []
        let mergedMeta = SyncedLibraryMeta(
            spaceOrder: order,
            savedViews: mergedViews,
            typeOrder: typeOrder,
            hiddenTypes: hiddenTypes
        )

        return CloudSyncSnapshot(
            spacesByID: mergedSpaces,
            libraryMeta: mergedMeta,
            settings: local.settings ?? remote.settings,
            activeSession: local.activeSession ?? remote.activeSession
        )
    }

    /// Build a `SessionSnapshot` view for iOS (or any read-only viewer): excludes
    /// archived Spaces, includes pinned forests + temporary doc tabs (dedup'd by
    /// path against pinned items), and attaches each Space's `activePath`.
    public func toSessionSnapshot() -> SessionSnapshot {
        let activeMap = activeSession?.activePathBySpace ?? [:]
        let published: [SessionSpaceSnapshot] = orderedSpaces().compactMap { space in
            guard !space.definition.isArchived else { return nil }
            var pinnedPaths = Set<String>()
            func convert(_ nodes: [SpaceDefinition.Node]) -> [SessionNode] {
                nodes.compactMap { node -> SessionNode? in
                    switch node {
                    case .item(let item):
                        guard let path = item.home.openPath else { return nil }
                        pinnedPaths.insert(path)
                        let title = item.customTitle ?? (path as NSString).lastPathComponent
                        return .doc(OpenDocSnapshot(path: path, title: title, type: EntryType.note.rawValue))
                    case .group(let group):
                        let kids = convert(group.children)
                        guard !kids.isEmpty else { return nil }
                        return .group(name: group.name, isCollapsed: false, children: kids)
                    }
                }
            }
            var roots = convert(space.definition.roots)
            var seenTempPaths = pinnedPaths
            for temp in space.temporaryTabs {
                guard let path = temp.openPath, seenTempPaths.insert(path).inserted else { continue }
                let title = temp.customTitle ?? (path as NSString).lastPathComponent
                roots.append(.doc(OpenDocSnapshot(path: path, title: title, type: EntryType.note.rawValue)))
            }
            guard !roots.isEmpty else { return nil }
            let active = activeMap[space.id.uuidString]
            return SessionSpaceSnapshot(id: space.id, name: space.definition.name,
                                        iconName: space.definition.iconName,
                                        roots: roots, activePath: active)
        }
        let stamp = activeSession?.updatedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        return SessionSnapshot(updatedAtMs: stamp, spaces: published)
    }
}
