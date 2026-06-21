import Foundation
import AppKit
import MarpleKit

/// Global handle to the running scheduler so the Settings scene (a separate
/// SwiftUI window, unreachable via the AppKit window's focus chain — same reason
/// as `ActiveModel`) can trigger 立即备份 / 浏览备份 and read the last-backup time.
@MainActor enum ActiveBackup {
    static let didChangeNotification = Notification.Name("marple.activeBackup.didChange")
    static var scheduler: BackupScheduler? {
        didSet { NotificationCenter.default.post(name: didChangeNotification, object: scheduler) }
    }
}

/// Drives periodic invisible whole-vault snapshots. On each tick (default once
/// per day) it snapshots only if the vault changed since the last backup, then
/// prunes to the tiered retention density. Snapshot/prune run off the main actor
/// (`SnapshotStore` is `Sendable`); UI-facing state stays on the main actor.
@MainActor
final class BackupScheduler: ObservableObject {
    let store: SnapshotStore
    private let policy = RetentionPolicy()
    private let interval: TimeInterval
    private var activity: NSBackgroundActivityScheduler?
    private var isDirty = true

    @Published private(set) var lastBackup: Date?
    @Published private(set) var isRunning = false
    private var snapshotInFlight = false

    init(store: SnapshotStore, interval: TimeInterval = 24 * 60 * 60) {
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
        guard activity == nil else { return }
        isDirty = true
        isRunning = true
        let a = NSBackgroundActivityScheduler(identifier: "io.marple.backup")
        a.repeats = true
        a.interval = interval
        a.tolerance = interval / 2
        a.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else { completion(.finished); return }
                self.scheduledTick { completion(.finished) }
            }
        }
        activity = a
    }

    func stop() {
        activity?.invalidate()
        activity = nil
        isRunning = false
    }

    func noteVaultChanged() {
        isDirty = true
    }

    /// Snapshot only if FSEvents saw a vault change since the previous check.
    func scheduledTick(onComplete: (@MainActor @Sendable () -> Void)? = nil) {
        guard isRunning else { onComplete?(); return }
        guard isDirty else { onComplete?(); return }
        guard !snapshotInFlight else { onComplete?(); return }
        isDirty = false
        if store.hasChanges(since: lastBackup) {
            runSnapshot(onComplete: onComplete)
        } else {
            onComplete?()
        }
    }

    /// Force a snapshot regardless of change state (立即备份 button).
    func backupNow() {
        guard !snapshotInFlight else { return }
        isDirty = false
        runSnapshot()
    }

    private func runSnapshot(onComplete: (@MainActor @Sendable () -> Void)? = nil) {
        // Serialize: a manual 立即备份 during an in-flight scheduled snapshot would
        // otherwise run two concurrent clones (and prune racing a snapshot).
        guard !snapshotInFlight else { onComplete?(); return }
        snapshotInFlight = true
        let store = self.store
        let policy = self.policy
        Task.detached {
            var succeeded = false
            do {
                _ = try store.snapshot()
                try store.prune(policy: policy)
                succeeded = true
            } catch {
                print("[marple] backup failed: \(error)")
            }
            let latest = store.lastBackupDate
            await MainActor.run {
                if !succeeded { self.isDirty = true }
                self.lastBackup = latest
                self.snapshotInFlight = false
                onComplete?()
            }
        }
    }
}
