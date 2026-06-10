import Foundation
import MarpleKit

/// Publishes the Mac's open document tabs to `<workspaceRoot>/session/open-tabs.json`
/// for the iOS companion to read. Mac-only — the iOS app never writes. This is the
/// same "Mac writes derived state into the synced folder" arrangement as the
/// `.marple` index; the open-tab list just lives outside `.marple` so it still syncs
/// even if the index directory is excluded from iCloud.
///
/// Publishes the **full recursive forest** (groups + their names + nesting), not a
/// flat tab list, so the iOS sidebar mirrors the Mac's 页面 folder structure and the
/// per-tab custom names (别名).
///
/// `persist()` fires on every state change, so this is debounced (~1.5s) and skips
/// the write entirely when the forest is unchanged — keeping iCloud churn down.
@MainActor
final class SessionWriter {
    private let workspaceRoot: String
    /// Last forest we committed to disk (timestamp ignored when comparing).
    private var lastRoots: [SessionNode] = []
    private var lastActive: String?
    private var pending: SessionSnapshot?
    private var scheduled = false

    init(workspaceRoot: String) { self.workspaceRoot = workspaceRoot }

    /// Build a snapshot from the active Space's tab forest and queue a debounced
    /// write. `tree` is the recursive (v2) snapshot whose tab leaves index into
    /// `tabs`; without it we fall back to a flat list of the tabs.
    func publish(tabs: [PersistedTab], tree: WorkspaceTreeSnapshot?, activeIndex: Int) {
        guard !workspaceRoot.isEmpty else { return }
        let roots: [SessionNode]
        if let tree {
            roots = tree.roots.compactMap { node(from: $0, tabs: tabs) }
        } else {
            roots = tabs.compactMap { leaf(from: $0).map(SessionNode.doc) }
        }
        let active = tabs.indices.contains(activeIndex) ? tabs[activeIndex].location.openPath : nil
        // Nothing materially changed → don't rewrite the file (avoids iCloud churn
        // on every scroll/selection that also triggers persist()).
        if roots == lastRoots && active == lastActive { return }
        lastRoots = roots
        lastActive = active
        pending = SessionSnapshot(updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                  roots: roots, activePath: active)
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
