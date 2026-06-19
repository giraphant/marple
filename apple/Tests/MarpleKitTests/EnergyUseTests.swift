import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct EnergyUseTests {
    @MainActor
    @Test func memoryWatchdogIsOptIn() {
        let suite = "marple-memory-watchdog-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!MemoryWatchdog.isEnabled(defaults: defaults, environment: [:], arguments: []))
        #expect(MemoryWatchdog.isEnabled(defaults: defaults, environment: ["MARPLE_MEMORY_WATCHDOG": "1"], arguments: []))
        #expect(MemoryWatchdog.isEnabled(defaults: defaults, environment: [:], arguments: ["Marple", "--memory-watchdog"]))

        defaults.set(true, forKey: SettingsKeys.memoryWatchdogEnabled)
        #expect(MemoryWatchdog.isEnabled(defaults: defaults, environment: [:], arguments: []))
    }

    @MainActor
    @Test func backupSchedulerSkipsCleanScheduledTicks() async throws {
        let (store, vault, base) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: base) }
        let scheduler = BackupScheduler(store: store)

        scheduler.start()
        defer { scheduler.stop() }
        await Self.runScheduledTick(scheduler)
        #expect(store.list().count == 1)

        await Self.runScheduledTick(scheduler)
        #expect(store.list().count == 1)
    }

    @MainActor
    @Test func backupSchedulerSnapshotsAfterDirtyChange() async throws {
        let (store, vault, base) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: base) }
        let scheduler = BackupScheduler(store: store)

        scheduler.start()
        defer { scheduler.stop() }
        await Self.runScheduledTick(scheduler)
        #expect(store.list().count == 1)
        let firstBackup = try #require(store.lastBackupDate)

        try await Task.sleep(nanoseconds: 2_100_000_000)
        let changed = vault.appendingPathComponent("vault/notes/a.md")
        try "changed".write(to: changed, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: changed.path)
        #expect(store.hasChanges(since: store.lastBackupDate))
        scheduler.noteVaultChanged()
        await Self.runScheduledTick(scheduler)
        let secondBackup = try #require(store.lastBackupDate)
        #expect(secondBackup > firstBackup)
    }

    @MainActor
    @Test func backupSchedulerStopDisablesRunningState() async throws {
        let (store, vault, base) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: base) }
        let scheduler = BackupScheduler(store: store)

        scheduler.start()
        #expect(scheduler.isRunning)
        scheduler.stop()
        #expect(!scheduler.isRunning)

        scheduler.noteVaultChanged()
        await Self.runScheduledTick(scheduler)
        #expect(store.list().isEmpty)
    }

    private static func makeStore() throws -> (SnapshotStore, URL, URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("marple-energy-\(UUID().uuidString)")
        let note = root.appendingPathComponent("vault/notes/a.md")
        try fm.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "alpha".write(to: note, atomically: true, encoding: .utf8)
        let base = fm.temporaryDirectory.appendingPathComponent("marple-energy-backups-\(UUID().uuidString)")
        return (SnapshotStore(workspaceRoot: root, backupsBase: base), root, base)
    }

    @MainActor private static func runScheduledTick(_ scheduler: BackupScheduler) async {
        await withCheckedContinuation { continuation in
            scheduler.scheduledTick { continuation.resume() }
        }
    }
}
