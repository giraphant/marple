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

    /// Resolve a CloudKit `CloudSyncSnapshot` directly against local `entries`,
    /// using each document's live `entry.title` whenever a tab has no custom alias.
    /// Archived Spaces, non-document tabs, unresolved docs, and empty groups/Spaces
    /// are pruned. Temporary document tabs already pinned in the same Space are
    /// deduped by path.
    public static func resolve(_ snapshot: CloudSyncSnapshot, entries: [Entry]) -> [ResolvedSessionSpace] {
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let activeMap = snapshot.activeSession?.activePathBySpace ?? [:]

        return snapshot.orderedSpaces().compactMap { space in
            guard !space.definition.isArchived else { return nil }
            var pinnedPaths = Set<String>()

            func resolveNodes(_ nodes: [SpaceDefinition.Node], prefix: String) -> [ResolvedSessionNode] {
                var used: [String: Int] = [:]
                return nodes.compactMap { node -> ResolvedSessionNode? in
                    switch node {
                    case .item(let item):
                        guard let path = item.home.openPath, let entry = byPath[path] else { return nil }
                        pinnedPaths.insert(path)
                        let id = "\(prefix)/\(path)#\(used[path, default: 0])"
                        used[path, default: 0] += 1
                        return .doc(id: id, entry: entry, label: item.customTitle ?? entry.title ?? (path as NSString).lastPathComponent)
                    case .group(let group):
                        let key = "g:\(group.name)"
                        let id = "\(prefix)/\(key)#\(used[key, default: 0])"
                        let kids = resolveNodes(group.children, prefix: id)
                        guard !kids.isEmpty else { return nil }
                        used[key, default: 0] += 1
                        return .group(id: id, name: group.name, isCollapsed: false, children: kids)
                    }
                }
            }

            var roots = resolveNodes(space.definition.roots, prefix: space.id.uuidString)
            var seenTempPaths = pinnedPaths
            var tempUsed: [String: Int] = [:]
            for temp in space.temporaryTabs {
                guard let path = temp.openPath,
                      seenTempPaths.insert(path).inserted,
                      let entry = byPath[path] else { continue }
                let id = "\(space.id.uuidString)/tmp/\(path)#\(tempUsed[path, default: 0])"
                tempUsed[path, default: 0] += 1
                roots.append(.doc(id: id, entry: entry, label: temp.customTitle ?? entry.title ?? (path as NSString).lastPathComponent))
            }
            guard !roots.isEmpty else { return nil }
            return ResolvedSessionSpace(
                id: space.id,
                name: space.definition.name,
                iconName: space.definition.iconName,
                roots: roots,
                activePath: activeMap[space.id.uuidString]
            )
        }
    }
}
