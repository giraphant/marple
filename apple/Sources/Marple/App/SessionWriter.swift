import Foundation
import MarpleKit

/// Publishes the Mac's open document tabs to `<workspaceRoot>/session/open-tabs.json`
/// for the iOS companion to read. Mac-only — the iOS app never writes. This is the
/// same "Mac writes derived state into the synced folder" arrangement as the
/// `.marple` index; the open-tab list just lives outside `.marple` so it still syncs
/// even if the index directory is excluded from iCloud.
///
/// Publishes **every Space** (name + icon + its full recursive forest of groups and
/// nesting), in sidebar order — not just the active one — so the iOS sidebar can
/// group by Space and mirror the Mac's 页面 folder structure and per-tab custom
/// names (别名).
///
/// `persist()` fires on every state change, so this is debounced (~1.5s) and skips
/// the write entirely when nothing material changed — keeping iCloud churn down.
@MainActor
final class SessionWriter {
    private let workspaceRoot: String
    /// Last space list we committed to disk (timestamp ignored when comparing).
    private var lastSpaces: [SessionSpaceSnapshot] = []
    private var pending: SessionSnapshot?
    private var scheduled = false

    init(workspaceRoot: String) { self.workspaceRoot = workspaceRoot }

    /// Build a snapshot of all Spaces' tab forests and queue a debounced write.
    /// Each Space's `tree` is the recursive (v2) snapshot whose tab leaves index
    /// into its `tabs`; without it we fall back to a flat list of the tabs. Spaces
    /// whose forest prunes to empty (e.g. browse-only) aren't published.
    func publish(spaces: [PersistedWorkspaceSpace]) {
        guard !workspaceRoot.isEmpty else { return }
        let published = spaces.compactMap { space -> SessionSpaceSnapshot? in
            let roots: [SessionNode]
            if let tree = space.tree {
                roots = tree.roots.compactMap { node(from: $0, tabs: space.tabs) }
            } else {
                roots = space.tabs.compactMap { leaf(from: $0).map(SessionNode.doc) }
            }
            guard !roots.isEmpty else { return nil }
            let active = space.tabs.indices.contains(space.activeIndex)
                ? space.tabs[space.activeIndex].location.openPath : nil
            return SessionSpaceSnapshot(id: space.id, name: space.name,
                                        iconName: space.iconName,
                                        roots: roots, activePath: active)
        }
        // Nothing materially changed → don't rewrite the file (avoids iCloud churn
        // on every scroll/selection that also triggers persist()).
        if published == lastSpaces { return }
        lastSpaces = published
        pending = SessionSnapshot(updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                  spaces: published)
        schedule()
    }

    /// Convert one tree node, pruning non-document leaves (browse tabs) and groups
    /// that end up empty after pruning.
    private func node(from n: WorkspaceTreeSnapshot.Node, tabs: [PersistedTab]) -> SessionNode? {
        switch n {
        case .tab(let i):
            guard tabs.indices.contains(i), let doc = leaf(from: tabs[i]) else { return nil }
            return .doc(doc)
        case .group(let g):
            let children = g.children.compactMap { node(from: $0, tabs: tabs) }
            guard !children.isEmpty else { return nil }
            return .group(name: g.name, isCollapsed: g.isCollapsed, children: children)
        }
    }

    /// A document tab → its published leaf (custom name takes precedence as the
    /// display label). Returns nil for non-document (browse) tabs.
    private func leaf(from tab: PersistedTab) -> OpenDocSnapshot? {
        guard let path = tab.location.openPath else { return nil }
        let title = tab.customTitle ?? tab.cachedTitle ?? (path as NSString).lastPathComponent
        return OpenDocSnapshot(path: path, title: title, type: (tab.cachedType ?? .note).rawValue)
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.flush() }
    }

    private func flush() {
        scheduled = false
        guard let snap = pending else { return }
        pending = nil
        let url = SessionFile.url(workspaceRoot: workspaceRoot)
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snap)
                try data.write(to: url, options: .atomic)
            } catch {
                print("[marple] session publish failed: \(error)")
            }
        }
    }
}
