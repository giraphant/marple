import Foundation
import MarpleKit

/// Publishes the Mac's open document tabs to `<workspaceRoot>/session/open-tabs.json`
/// for the iOS companion to read. Mac-only — the iOS app never writes. This is the
/// same "Mac writes derived state into the synced folder" arrangement as the
/// `.marple` index; the open-tab list just lives outside `.marple` so it still syncs
/// even if the index directory is excluded from iCloud.
///
/// `persist()` fires on every state change, so this is debounced (~1.5s) and skips
/// the write entirely when the open-doc set is unchanged — keeping iCloud churn down.
@MainActor
final class SessionWriter {
    private let workspaceRoot: String
    /// Last payload we committed to disk (timestamp ignored when comparing).
    private var lastDocs: [OpenDocSnapshot] = []
    private var lastActive: String?
    private var pending: SessionSnapshot?
    private var scheduled = false

    init(workspaceRoot: String) { self.workspaceRoot = workspaceRoot }

    /// Build a snapshot from the active Space's tabs and queue a debounced write.
    func publish(tabs: [PersistedTab], activeIndex: Int) {
        guard !workspaceRoot.isEmpty else { return }
        let docs: [OpenDocSnapshot] = tabs.compactMap { tab in
            guard let path = tab.location.openPath else { return nil }   // skip browse tabs
            let title = tab.customTitle ?? tab.cachedTitle ?? (path as NSString).lastPathComponent
            return OpenDocSnapshot(path: path, title: title, type: (tab.cachedType ?? .note).rawValue)
        }
        let active = tabs.indices.contains(activeIndex) ? tabs[activeIndex].location.openPath : nil
        // Nothing materially changed → don't rewrite the file (avoids iCloud churn
        // on every scroll/selection that also triggers persist()).
        if docs == lastDocs && active == lastActive { return }
        lastDocs = docs
        lastActive = active
        pending = SessionSnapshot(updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                  openDocs: docs, activePath: active)
        schedule()
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
