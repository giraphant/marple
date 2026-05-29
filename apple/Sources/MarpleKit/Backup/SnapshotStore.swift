import Foundation
import CryptoKit

/// Owns the backup root for one vault and performs whole-vault snapshots,
/// listing, pruning, and single-document restore-as-copy.
///
/// Layout: `<backupsBase>/<vault-id>/<yyyy-MM-dd_HH-mm-ss>/` — one directory per
/// snapshot, each a `clonefile(2)` tree of the vault (minus excluded children).
/// The vault id keeps multiple vaults from colliding under a shared base.
public final class SnapshotStore: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var date: Date
        public var url: URL
    }

    public enum BackupError: Error {
        case notFound
    }

    public let workspaceRoot: URL
    public let backupRoot: URL

    public init(workspaceRoot: URL, backupsBase: URL) {
        self.workspaceRoot = workspaceRoot
        self.backupRoot = backupsBase.appendingPathComponent(Self.vaultID(for: workspaceRoot))
    }

    /// Stable per-vault id: short SHA256 of the absolute path, prefixed with the
    /// leaf folder name so the directory is human-recognizable.
    public static func vaultID(for root: URL) -> String {
        let path = root.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(path.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        let leaf = root.lastPathComponent.isEmpty ? "vault" : root.lastPathComponent
        return "\(leaf)-\(hash)"
    }

    // MARK: - Naming

    private static let dirFormat = "yyyy-MM-dd_HH-mm-ss"

    private func dirFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Self.dirFormat
        return f
    }

    private func displayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f.string(from: date)
    }

    // MARK: - Listing

    /// All snapshots, newest first. Names that don't parse as timestamps are
    /// ignored (e.g. a leftover `.tmp-*` from an interrupted clone).
    public func list() -> [Snapshot] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: backupRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        let parser = dirFormatter()
        var out: [Snapshot] = []
        for url in entries {
            guard let date = parser.date(from: url.lastPathComponent) else { continue }
            out.append(Snapshot(date: date, url: url))
        }
        return out.sorted { $0.date > $1.date }
    }

    public var lastBackupDate: Date? { list().first?.date }

    // MARK: - Snapshot

    /// Clone the vault into a temp dir, then atomically rename to the timestamped
    /// name so a crash mid-clone never leaves a valid-looking partial snapshot.
    @discardableResult
    public func snapshot(now: Date = Date()) throws -> Snapshot {
        let fm = FileManager.default
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let name = dirFormatter().string(from: now)
        let final = backupRoot.appendingPathComponent(name)
        let tmp = backupRoot.appendingPathComponent(".tmp-\(UUID().uuidString)")

        try CloneCopy.snapshotTree(from: workspaceRoot, to: tmp)
        if fm.fileExists(atPath: final.path) {
            try fm.removeItem(at: final)  // same-second re-snapshot: replace
        }
        try fm.moveItem(at: tmp, to: final)
        return Snapshot(date: now, url: final)
    }

    // MARK: - Prune

    public func prune(now: Date = Date(), policy: RetentionPolicy = RetentionPolicy()) throws {
        let snaps = list()
        let decision = policy.evaluate(snapshots: snaps.map(\.date), now: now)
        let drop = Set(decision.delete)
        let fm = FileManager.default
        for snap in snaps where drop.contains(snap.date) {
            try? fm.removeItem(at: snap.url)
        }
    }

    // MARK: - Change detection

    /// True if anything under the vault changed since `since` (add / modify /
    /// delete). Walks the tree skipping excluded dirs; a deletion is caught via
    /// the parent directory's own modification date. `nil` since ⇒ always true.
    public func hasChanges(since: Date?) -> Bool {
        guard let since else { return true }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        // A top-level deletion bumps the root's own mtime; the enumerator never
        // visits the root itself, so check it explicitly.
        if let rootM = try? workspaceRoot.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate, rootM > since {
            return true
        }

        guard let walker = fm.enumerator(
            at: workspaceRoot, includingPropertiesForKeys: keys,
            options: [], errorHandler: nil
        ) else { return true }

        for case let url as URL in walker {
            let name = url.lastPathComponent
            if CloneCopy.isExcluded(name) {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if let m = values?.contentModificationDate, m > since {
                return true
            }
        }
        return false
    }

    // MARK: - Restore

    /// Copy one file/dir out of `snapshot` into the live vault under a
    /// non-colliding sibling name (never overwrites). Returns the new rel path.
    @discardableResult
    public func restoreCopy(snapshot: Snapshot, relPath: String) throws -> String {
        let fm = FileManager.default
        let src = snapshot.url.appendingPathComponent(relPath)
        guard fm.fileExists(atPath: src.path) else { throw BackupError.notFound }

        let relURL = URL(fileURLWithPath: relPath)
        let dir = relURL.deletingLastPathComponent().path
        let ext = relURL.pathExtension
        let stem = relURL.deletingPathExtension().lastPathComponent
        let suffix = " (恢复自 \(displayStamp(snapshot.date)))"

        func compose(_ stem: String) -> String {
            let leaf = ext.isEmpty ? stem : "\(stem).\(ext)"
            return dir == "." || dir.isEmpty ? leaf : "\(dir)/\(leaf)"
        }

        var candidateRel = compose(stem + suffix)
        var n = 2
        while fm.fileExists(atPath: workspaceRoot.appendingPathComponent(candidateRel).path) {
            candidateRel = compose(stem + suffix + " \(n)")
            n += 1
        }
        let dst = workspaceRoot.appendingPathComponent(candidateRel)
        try fm.createDirectory(at: dst.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: dst)
        return candidateRel
    }

    /// Markdown documents inside a snapshot's `vault/`, as vault-relative paths.
    public func documents(in snapshot: Snapshot) -> [String] {
        let fm = FileManager.default
        let vaultDir = snapshot.url.appendingPathComponent("vault")
        guard let walker = fm.enumerator(
            at: vaultDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles], errorHandler: nil
        ) else { return [] }
        var out: [String] = []
        let base = snapshot.url.standardizedFileURL.path
        for case let url as URL in walker where url.pathExtension == "md" {
            let full = url.standardizedFileURL.path
            if full.hasPrefix(base + "/") {
                out.append(String(full.dropFirst(base.count + 1)))
            }
        }
        return out.sorted()
    }
}
