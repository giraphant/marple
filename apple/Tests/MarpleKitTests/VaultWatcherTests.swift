import Foundation
import Testing
@testable import MarpleKit

@Suite struct VaultWatcherTests {
    actor Probe {
        private var count = 0
        func signal() { count += 1 }
        func reset() { count = 0 }
        func fired() -> Bool { count > 0 }
    }

    @Test func testCoalescerFiresOnceAfterBurst() async {
        let fired = Coalescer.Box()
        let c = Coalescer(interval: 0.05) { await fired.bump() }
        c.signal(); c.signal(); c.signal()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let n = await fired.count
        #expect(n == 1)
    }

    @Test func watcherFiresForNestedFileContentChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultWatcherTests-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        let papers = vault.appendingPathComponent("papers")
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        let file = papers.appendingPathComponent("a.md")
        try "---\ntype: paper\ntitle: Before\n---\n".write(to: file, atomically: true, encoding: .utf8)

        let probe = Probe()
        let watcher = VaultWatcher(vaultDirectory: vault, debounce: 0.05)
        watcher.start { Task { await probe.signal() } }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 200_000_000)
        await probe.reset()
        try "---\ntype: paper\ntitle: After\n---\n".write(to: file, atomically: true, encoding: .utf8)

        try await expectFired(probe, message: "watcher should fire for nested markdown file content changes")
    }

    @Test func watcherFiresForNestedFileCreation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultWatcherTests-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        let notes = vault.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

        let probe = Probe()
        let watcher = VaultWatcher(vaultDirectory: vault, debounce: 0.05)
        watcher.start { Task { await probe.signal() } }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 200_000_000)
        await probe.reset()
        let file = notes.appendingPathComponent("iphone2.md")
        try "---\ntype: note\ntitle: \"搞你的 iPhone2\"\ncreated: 2026-05-18\n---\n".write(to: file, atomically: true, encoding: .utf8)

        try await expectFired(probe, message: "watcher should fire for nested markdown file creation")
    }

    private func expectFired(_ probe: Probe, message: String) async throws {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await probe.fired() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(Bool(false), Comment(rawValue: message))
    }
}
