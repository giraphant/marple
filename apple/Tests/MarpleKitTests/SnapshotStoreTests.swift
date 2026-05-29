import Testing
import Foundation
@testable import MarpleKit

@Suite struct SnapshotStoreTests {
    private let fm = FileManager.default

    private func makeVault() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("marple-store-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("vault/notes/a.md", "alpha")
        try write("vault/notes/b.md", "beta")
        try write("sources/x.pdf", "PDF")
        try write(".marple/index.sqlite", "cache")
        return root
    }

    private func makeStore() throws -> (SnapshotStore, URL, URL) {
        let vault = try makeVault()
        let base = fm.temporaryDirectory.appendingPathComponent("marple-backups-\(UUID().uuidString)")
        return (SnapshotStore(workspaceRoot: vault, backupsBase: base), vault, base)
    }

    @Test func vaultIDIsStableAndScoped() {
        let a = SnapshotStore.vaultID(for: URL(fileURLWithPath: "/Users/me/Documents/bts"))
        let b = SnapshotStore.vaultID(for: URL(fileURLWithPath: "/Users/me/Documents/bts"))
        let c = SnapshotStore.vaultID(for: URL(fileURLWithPath: "/Users/me/Documents/other"))
        #expect(a == b)
        #expect(a != c)
        #expect(a.hasPrefix("bts-"))
    }

    @Test func snapshotThenListRoundTrips() throws {
        let (store, vault, base) = try makeStore()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }

        let snap = try store.snapshot(now: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(fm.fileExists(atPath: snap.url.appendingPathComponent("vault/notes/a.md").path))
        #expect(!fm.fileExists(atPath: snap.url.appendingPathComponent(".marple").path))

        let listed = store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.url.lastPathComponent == snap.url.lastPathComponent)
        #expect(store.lastBackupDate == snap.date)
    }

    @Test func listIgnoresTempAndNewestFirst() throws {
        let (store, vault, base) = try makeStore()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }

        let older = try store.snapshot(now: Date(timeIntervalSince1970: 1_780_000_000))
        let newer = try store.snapshot(now: Date(timeIntervalSince1970: 1_780_100_000))
        // A stray temp dir must be ignored by list().
        try fm.createDirectory(at: store.backupRoot.appendingPathComponent(".tmp-leftover"),
                               withIntermediateDirectories: true)

        let listed = store.list()
        #expect(listed.map(\.date) == [newer.date, older.date])
    }

    @Test func pruneDeletesDroppedDirs() throws {
        let (store, vault, base) = try makeStore()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }
        let now = Date(timeIntervalSince1970: 1_780_056_000)

        // Two snapshots in the same calendar hour → daily/hourly tier collapses to newest.
        let s1 = try store.snapshot(now: now.addingTimeInterval(-600))  // 10 min ago
        let s2 = try store.snapshot(now: now.addingTimeInterval(-60))   // 1 min ago

        try store.prune(now: now)
        let remaining = Set(store.list().map(\.date))
        #expect(remaining.contains(s2.date))
        #expect(!remaining.contains(s1.date))
    }

    @Test func hasChangesDetectsModification() throws {
        let (store, vault, base) = try makeStore()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }

        #expect(store.hasChanges(since: nil))  // nil baseline ⇒ always dirty

        let baseline = Date()
        // Nothing touched after baseline (allow a tick of slack on coarse mtimes).
        Thread.sleep(forTimeInterval: 0.05)
        let after = Date()
        try "changed".write(to: vault.appendingPathComponent("vault/notes/a.md"),
                            atomically: true, encoding: .utf8)
        #expect(store.hasChanges(since: after))
        _ = baseline
    }

    @Test func hasChangesIgnoresExcludedDirs() throws {
        let (store, vault, base) = try makeStore()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }

        let baseline = Date()
        Thread.sleep(forTimeInterval: 0.05)
        // Only the rebuildable cache changes → not a real vault change.
        try "rebuilt".write(to: vault.appendingPathComponent(".marple/index.sqlite"),
                            atomically: true, encoding: .utf8)
        #expect(!store.hasChanges(since: baseline))
    }

    @Test func hasChangesDetectsTopLevelDeletion() throws {
        let (store, vault, base) = try makeStore()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }

        let baseline = Date()
        Thread.sleep(forTimeInterval: 0.05)
        // Delete a top-level child → only the vault root's mtime changes.
        try fm.removeItem(at: vault.appendingPathComponent("sources"))
        #expect(store.hasChanges(since: baseline))
    }

    @Test func restoreCopyNeverOverwritesOriginal() throws {
        let (store, vault, base) = try makeStore()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }

        let snap = try store.snapshot(now: Date(timeIntervalSince1970: 1_780_000_000))
        // Mutate the live file after the snapshot.
        let live = vault.appendingPathComponent("vault/notes/a.md")
        try "edited".write(to: live, atomically: true, encoding: .utf8)

        let newRel = try store.restoreCopy(snapshot: snap, relPath: "vault/notes/a.md")
        #expect(newRel != "vault/notes/a.md")
        #expect(newRel.contains("恢复自"))

        let original = try String(contentsOf: live, encoding: .utf8)
        #expect(original == "edited")  // untouched
        let restored = try String(contentsOf: vault.appendingPathComponent(newRel), encoding: .utf8)
        #expect(restored == "alpha")  // snapshot content
    }

    @Test func restoreCopyThrowsOnMissing() throws {
        let (store, vault, base) = try makeStore()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }
        let snap = try store.snapshot(now: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(throws: SnapshotStore.BackupError.self) {
            try store.restoreCopy(snapshot: snap, relPath: "vault/notes/nope.md")
        }
    }

    @Test func documentsListsMarkdownOnly() throws {
        let (store, vault, base) = try makeStore()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }
        let snap = try store.snapshot(now: Date(timeIntervalSince1970: 1_780_000_000))
        let docs = store.documents(in: snap)
        #expect(docs == ["vault/notes/a.md", "vault/notes/b.md"])
    }
}
