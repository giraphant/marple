import Foundation

/// The Mac's open-tab forest resolved for display: a document leaf (carrying the
/// resolved entry for navigation + the Mac's display label) or a named group with
/// children. `id` is a stable per-node tag assigned during resolution.
///
/// `Identifiable` is a Swift standard-library protocol (not SwiftUI), so this type
/// lives in MarpleKit and the iOS SwiftUI sidebar consumes it directly.
public enum ResolvedSessionNode: Identifiable {
    case doc(id: String, entry: Entry, label: String)
    case group(id: String, name: String, isCollapsed: Bool, children: [ResolvedSessionNode])

    public var id: String {
        switch self {
        case .doc(let id, _, _): return id
        case .group(let id, _, _, _): return id
        }
    }
}

/// One Mac Space resolved for display: its name + icon (SF Symbol, as set on the
/// Mac) and its resolved tab forest. Spaces whose forest resolves to empty are
/// pruned before this is built.
public struct ResolvedSessionSpace: Identifiable {
    public let id: UUID
    public let name: String
    public let iconName: String?
    public let roots: [ResolvedSessionNode]
    /// That Space's active tab path (Mac-side), for the subtle "you are here" mark.
    public let activePath: String?

    public init(id: UUID, name: String, iconName: String?,
                roots: [ResolvedSessionNode], activePath: String?) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.roots = roots
        self.activePath = activePath
    }
}

/// Resolves the Mac-published open-tabs.json (`SessionSnapshot`) into a displayable
/// forest against the local `entries` (QUA-218 PR4 down-sink). Platform-agnostic:
/// pure path→entry resolution + pruning of unresolved docs, empty groups, and empty
/// Spaces. File load / iCloud download stay iOS-side (platform IO).
public enum SessionResolver {
    /// Verbatim port of `ReaderModel.loadSession`'s resolution segment (byPath
    /// lookup + recursive prune + counter IDs).
    public static func resolve(_ snapshot: SessionSnapshot, entries: [Entry]) -> [ResolvedSessionSpace] {
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var counter = 0
        func resolveNodes(_ nodes: [SessionNode]) -> [ResolvedSessionNode] {
            nodes.compactMap { node -> ResolvedSessionNode? in
                counter += 1
                switch node {
                case .doc(let d):
                    guard let entry = byPath[d.path] else { return nil }
                    return .doc(id: "n\(counter)", entry: entry, label: d.title)
                case .group(let name, let collapsed, let children):
                    let kids = resolveNodes(children)
                    guard !kids.isEmpty else { return nil }
                    return .group(id: "n\(counter)", name: name, isCollapsed: collapsed, children: kids)
                }
            }
        }
        return snapshot.spaces.compactMap { space in
            let roots = resolveNodes(space.roots)
            guard !roots.isEmpty else { return nil }
            return ResolvedSessionSpace(id: space.id, name: space.name,
                                        iconName: space.iconName, roots: roots,
                                        activePath: space.activePath)
        }
    }
}
