import Testing
import Foundation
@testable import MarpleKit

@Suite struct CloneCopyTests {
    private let fm = FileManager.default

    private func makeTempVault() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("marple-clone-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("vault/notes/a.md", "hello")
        try write("sources/x.pdf", "PDFDATA")
        try write(".marple/index.sqlite", "cache")
        try write(".git/HEAD", "ref")
        try write(".DS_Store", "junk")
        try write(".sync_abc123.db", "syncjournal")
        try write(".obsidian/app.json", "{}")
        try write(".claude/session.json", "agent")
        try write(".superset/state.json", "agent")
        return root
    }

    @Test func excludesCachesVCSandJunkKeepsContent() throws {
        let root = try makeTempVault()
        defer { try? fm.removeItem(at: root) }
        let dest = fm.temporaryDirectory.appendingPathComponent("marple-snap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dest) }

        try CloneCopy.snapshotTree(from: root, to: dest)

        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: dest.appendingPathComponent(rel).path) }
        #expect(exists("vault/notes/a.md"))
        #expect(exists("sources/x.pdf"))
        #expect(exists(".obsidian/app.json"))   // user-facing tool config is kept
        #expect(!exists(".marple"))
        #expect(!exists(".git"))
        #expect(!exists(".DS_Store"))
        #expect(!exists(".sync_abc123.db"))
        #expect(!exists(".claude"))             // agent session state
        #expect(!exists(".superset"))

        let copied = try String(contentsOf: dest.appendingPathComponent("vault/notes/a.md"), encoding: .utf8)
        #expect(copied == "hello")
    }

    @Test func isExcludedMatching() {
        #expect(CloneCopy.isExcluded(".marple"))
        #expect(CloneCopy.isExcluded(".git"))
        #expect(CloneCopy.isExcluded(".DS_Store"))
        #expect(CloneCopy.isExcluded(".sync_555605ba2bcb.db"))
        #expect(CloneCopy.isExcluded(".sync_555605ba2bcb.db-wal"))
        #expect(CloneCopy.isExcluded(".claude"))
        #expect(CloneCopy.isExcluded(".superset"))
        #expect(CloneCopy.isExcluded(".codex"))
        #expect(!CloneCopy.isExcluded("vault"))
        #expect(!CloneCopy.isExcluded(".obsidian"))
    }
}
