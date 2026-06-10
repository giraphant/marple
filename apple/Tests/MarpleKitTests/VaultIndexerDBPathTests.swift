import Testing
import Foundation
@testable import MarpleKit

@Suite struct VaultIndexerDBPathTests {
    @Test func indexerWritesToOverridePathNotWorkspace() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("marple-idx-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        try "---\ntype: note\ntitle: Hi\n---\nbody".write(
            to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let outDB = root.appendingPathComponent("container/index.sqlite")
        let indexer = VaultIndexer(workspaceRoot: root.path, indexDBPath: outDB.path)
        _ = try indexer.buildFull()

        #expect(fm.fileExists(atPath: outDB.path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".marple/index.sqlite").path))
        try? fm.removeItem(at: root)
    }
}
