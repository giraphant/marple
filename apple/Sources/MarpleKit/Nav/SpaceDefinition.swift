import Foundation

/// The part of a Space every window shares: its name/icon/archive flag and the
/// pinned-page forest (pinned tabs + folders, with stable ids). Reading state —
/// histories, selection, temporary pages, folder collapse — is NOT here; each
/// window keeps that in its own `Workspace` copy. See docs/multi-window-design.md.
public struct SpaceDefinition: Identifiable, Hashable, Sendable {
    /// A pinned page. `id` is the `NavTab.id` the page carries in every window.
    public struct Item: Hashable, Sendable {
        public var id: UUID
        public var home: NavLocation
        public var customTitle: String?
        public var cachedTitle: String?
        public var cachedType: EntryType?

        public init(id: UUID, home: NavLocation, customTitle: String? = nil,
                    cachedTitle: String? = nil, cachedType: EntryType? = nil) {
            self.id = id
            self.home = home
            self.customTitle = customTitle
            self.cachedTitle = cachedTitle
            self.cachedType = cachedType
        }
    }

    public struct Group: Hashable, Sendable {
        public var id: UUID
        public var name: String
        public var children: [Node]

        public init(id: UUID, name: String, children: [Node]) {
            self.id = id
            self.name = name
            self.children = children
        }
    }

    public enum Node: Hashable, Sendable {
        case item(Item)
        case group(Group)
    }

    public let id: UUID
    public var name: String
    public var iconName: String?
    public var isArchived: Bool
    public var roots: [Node]

    public init(id: UUID, name: String, iconName: String? = nil, isArchived: Bool = false,
                roots: [Node] = []) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.isArchived = isArchived
        self.roots = roots
    }

    /// Every pinned item at any depth, in sidebar order.
    public var items: [Item] {
        func walk(_ nodes: [Node]) -> [Item] {
            nodes.flatMap { node -> [Item] in
                switch node {
                case .item(let item): return [item]
                case .group(let group): return walk(group.children)
                }
            }
        }
        return walk(roots)
    }
}

public extension WorkspaceSpace {
    /// This window's view of the Space, reduced to what all windows share.
    var definition: SpaceDefinition {
        SpaceDefinition(id: id, name: name, iconName: iconName, isArchived: isArchived,
                        roots: workspace?.sharedRoots ?? [])
    }

    /// A Space this window has not shown yet: the shared pinned pages at their
    /// anchors, nothing temporary, browsing.
    init(definition: SpaceDefinition, collapsedGroupIDs: Set<UUID> = []) {
        var workspace = Workspace()
        workspace.rebase(onto: definition.roots, defaultCollapsed: collapsedGroupIDs)
        self.init(id: definition.id, name: definition.name,
                  workspace: workspace.isEmpty ? nil : workspace, isBrowsing: true,
                  iconName: definition.iconName, isArchived: definition.isArchived)
    }

    /// Take another window's change to the shared part, keeping this window's
    /// histories, selection, temporary pages and folder collapse.
    mutating func adopt(_ definition: SpaceDefinition) {
        name = definition.name
        iconName = definition.iconName
        isArchived = definition.isArchived
        var ws = workspace ?? Workspace()
        ws.rebase(onto: definition.roots)
        workspace = ws.isEmpty ? nil : ws
        if workspace?.tabs.isEmpty != false { isBrowsing = true }
    }
}

public extension Array where Element == WorkspaceSpace {
    /// Rebuild this window's Space list on the shared definitions: shared order,
    /// new Spaces added at their anchors, deleted Spaces dropped.
    func adopting(_ definitions: [SpaceDefinition]) -> [WorkspaceSpace] {
        let existing = Dictionary(map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return definitions.map { definition in
            guard var space = existing[definition.id] else { return WorkspaceSpace(definition: definition) }
            space.adopt(definition)
            return space
        }
    }
}
