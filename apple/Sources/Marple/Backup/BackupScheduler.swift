import Foundation
import MarpleKit

/// Global handle to the running scheduler so the Settings scene (a separate
/// SwiftUI window, unreachable via the AppKit window's focus chain — same reason
/// as `ActiveModel`) can trigger 立即备份 / 浏览备份 and read the last-backup time.
@MainActor enum ActiveBackup { static var scheduler: BackupScheduler? }

/// Drives periodic invisible whole-vault snapshots. On each tick (default every
/// 15 min) it snapshots only if the vault changed since the last backup, then
/// prunes to the tiered retention density. Snapshot/prune run off the main actor
/// (`SnapshotStore` is `Sendable`); UI-facing state stays on the main actor.
@MainActor
final class BackupScheduler: ObservableObject {
    let store: SnapshotStore
    private let policy = RetentionPolicy()
    private let interval: TimeInterval
    private var timer: Timer?

    @Published private(set) var lastBackup: Date?
    @Published private(set) var isRunning = false
    private var snapshotInFlight = false

    init(store: SnapshotStore, interval: TimeInterval = 15 * 60) {
        self.store = store
        self.interval = interval
        self.lastBackup = store.lastBackupDate
    }

    /// Default backup base: `~/Library/Application Support/Marple/Backups/`.
    /// Honors `marple.backupLocation` when the user picked a custom folder.
    static func resolveBase() -> URL {
        let custom = UserDefaults.standard.string(forKey: SettingsKeys.backupLocation) ?? ""
        if !custom.isEmpty { return URL(fileURLWithPath: custom) }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Marple/Backups", isDirectory: true)
    }

    func start() {
        guard timer == nil else { return }
        isRunning = true
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// Snapshot only if the vault changed since the last backup.
    private func tick() {
        if store.hasChanges(since: store.lastBackupDate) {
            runSnapshot()
        }
    }

    /// Force a snapshot regardless of change state (立即备份 button).
    func backupNow() { runSnapshot() }

    private func runSnapshot() {
        // Serialize: a manual 立即备份 during an in-flight scheduled snapshot would
        // otherwise run two concurrent clones (and prune racing a snapshot).
        guard !snapshotInFlight else { return }
        snapshotInFlight = true
        let store = self.store
        let policy = self.policy
        Task.detached {
            do {
                _ = try store.snapshot()
                try store.prune(policy: policy)
            } catch {
                print("[marple] backup failed: \(error)")
            }
            let latest = store.lastBackupDate
            await MainActor.run {
                self.lastBackup = latest
                self.snapshotInFlight = false
            }
        }
    }
}
