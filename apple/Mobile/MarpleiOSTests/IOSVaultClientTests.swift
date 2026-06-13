import XCTest
import MarpleKit
@testable import MarpleiOS

final class IOSVaultClientTests: XCTestCase {
    func testIndexAndEntryTextOverFixtureVault() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ios-vc-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        let md = "---\ntype: note\ntitle: Hello\n---\nthe body text"
        try md.write(to: vault.appendingPathComponent("hello.md"), atomically: true, encoding: .utf8)

        let dbPath = root.appendingPathComponent("container/index.sqlite").path
        let indexer = VaultIndexer(workspaceRoot: root.path, indexDBPath: dbPath)
        _ = try indexer.buildFull()

        let client = IOSVaultClient(workspaceRoot: root.path, db: IndexDatabase(indexDBPath: dbPath))
        let entries = try await client.index()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "Hello")

        let text = try await client.entryText(path: "vault/hello.md")
        XCTAssertTrue(text.contains("the body text"))
        try? fm.removeItem(at: root)
    }
}
