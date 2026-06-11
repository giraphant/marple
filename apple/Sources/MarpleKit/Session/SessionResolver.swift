import Foundation

/// The Mac's open-tab forest resolved for display: a document leaf (carrying the
/// resolved entry for navigation + the Mac's display label) or a named group with
/// children. `id` is a content-derived tag (ancestry path + the node's own path /
/// group name) that stays put across re-resolves, so SwiftUI animates rather than
/// resets when the Mac's unresolved set shifts (QUA-228).
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
    /// byPath lookup + recursive prune, assigning each surviving node an ID built
    /// from its ancestry: `<parent>/<key>#<occurrence>`, where `key` is the doc's
    /// path or `g:<group name>`. The occurrence index counts only *surviving*
    /// same-key siblings, so an unresolved (pruned) node never consumes a slot —
    /// adding/removing one leaves every survivor's ID untouched (QUA-228). The
    /// occurrence suffix only ever moves when a genuine duplicate (same path or
    /// group name in one parent) appears or disappears.
    public static func resolve(_ snapshot: SessionSnapshot, entries: [Entry]) -> [ResolvedSessionSpace] {
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        func resolveNodes(_ nodes: [SessionNode], prefix: String) -> [ResolvedSessionNode] {
            var used: [String: Int] = [:]
            return nodes.compactMap { node -> ResolvedSessionNode? in
                switch node {
                case .doc(let d):
                    guard let entry = byPath[d.path] else { return nil }
                    let key = d.path
                    let id = "\(prefix)/\(key)#\(used[key, default: 0])"
                    used[key, default: 0] += 1
                    return .doc(id: id, entry: entry, label: d.title)
                case .group(let name, let collapsed, let children):
                    let key = "g:\(name)"
                    let id = "\(prefix)/\(key)#\(used[key, default: 0])"
                    let kids = resolveNodes(children, prefix: id)
                    guard !kids.isEmpty else { return nil }
                    used[key, default: 0] += 1
                    return .group(id: id, name: name, isCollapsed: collapsed, children: kids)
                }
            }
        }
        return snapshot.spaces.compactMap { space in
            let roots = resolveNodes(space.roots, prefix: space.id.uuidString)
            guard !roots.isEmpty else { return nil }
            return ResolvedSessionSpace(id: space.id, name: space.name,
                                        iconName: space.iconName, roots: roots,
                                        activePath: space.activePath)
        }
    }
}
