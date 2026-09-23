import Foundation
import Testing
import GRDB
@testable import MarpleKit

@Suite struct MetadataResilienceTests {
    @Test func stalledPathTimesOutWhileHealthyPathsProgress() {
        let release = DispatchSemaphore(value: 0)
        // Cleanup also releases a deliberately synchronous baseline implementation.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        let reader = MetadataReader(timeout: 0.05, maximumInFlight: 2) { path in
            if path == "stalled" { release.wait(); return 99 }
            return 42
        }
        let start = ContinuousClock.now
        #expect(reader.mtimeMs(atPath: "stalled") == nil)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(reader.mtimeMs(atPath: "healthy") == 42)
        release.signal()
    }

    @Test func repeatedStalledPathDoesNotConsumeAnotherWorker() {
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for _ in 0..<4 { release.signal() }
        }
        let calls = LockedCounter()
        let reader = MetadataReader(timeout: 0.02, maximumInFlight: 2) { path in
            if path == "stalled" { calls.increment(); release.wait(); return 99 }
            return 42
        }
        for _ in 0..<4 { _ = reader.mtimeMs(atPath: "stalled") }
        #expect(calls.value == 1)
        #expect(reader.mtimeMs(atPath: "healthy") == 42)
        release.signal()
    }

    @Test func saturatedReaderSkipsInsteadOfSpawningUnboundedWorkers() {
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for _ in 0..<8 { release.signal() }
        }
        let calls = LockedCounter()
        let reader = MetadataReader(timeout: 0.02, maximumInFlight: 2) { _ in
            calls.increment(); release.wait(); return 99
        }
        for i in 0..<8 { _ = reader.mtimeMs(atPath: "stalled-\(i)") }
        #expect(calls.value == 2)
        for _ in 0..<8 { release.signal() }
    }

    @Test func fullRebuildKeepsReadableFilesWhenMetadataIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["unknown", "healthy"] {
            try "---\ntype: paper\ntitle: \(name)\n---\nBody".write(
                to: vault.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        let reader = MetadataReader { path in path.hasSuffix("unknown.md") ? nil : 42 }
        let indexer = VaultIndexer(workspaceRoot: root.path, metadataReader: reader)
        #expect(try indexer.buildFull() == 2)
        let rows = try DatabaseQueue(path: root.path + "/.marple/index.sqlite").read { db in
            try Row.fetchAll(db, sql: "SELECT path, mtime FROM entries ORDER BY path")
        }
        #expect(rows.count == 2)
        #expect(rows.first?["mtime"] as Int64? == 42)
        #expect(rows.last?["path"] as String? == "vault/unknown.md")
        #expect(rows.last?["mtime"] as Int64? == nil)
    }

    @Test func unavailableMetadataRetainsExistingRowAndIndexesHealthyFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\ntype: paper\ntitle: Keep\n---\nBody".write(
            to: vault.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
        _ = try VaultIndexer(workspaceRoot: root.path).buildFull()
        try "---\ntype: paper\ntitle: New\n---\nBody".write(
            to: vault.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        let reader = MetadataReader { path in
            path.hasSuffix("keep.md") ? nil : MetadataReader.fileMtimeMs(atPath: path)
        }
        let indexer = VaultIndexer(workspaceRoot: root.path, metadataReader: reader)
        let stats = try indexer.reconcile()
        #expect(stats.upserted == 1)
        #expect(stats.removed == 0)
        let rows = try DatabaseQueue(path: root.path + "/.marple/index.sqlite").read { db in
            try String.fetchAll(db, sql: "SELECT path FROM entries ORDER BY path")
        }
        #expect(rows == ["vault/keep.md", "vault/new.md"])
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
