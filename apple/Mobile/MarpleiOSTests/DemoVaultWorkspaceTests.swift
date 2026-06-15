import XCTest
import MarpleKit
@testable import MarpleiOS

final class DemoVaultWorkspaceTests: XCTestCase {
    func testDemoVaultIsIndexableAndReadable() async throws {
        #if DEBUG && targetEnvironment(simulator)
        let root = try DemoVaultWorkspace.prepare()
        let dbPath = DemoVaultWorkspace.indexDBPath(workspaceRoot: root).path

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("vault").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionFile.url(workspaceRoot: root.path).path))

        let count = try VaultIndexer(workspaceRoot: root.path, indexDBPath: dbPath).buildFull()
        XCTAssertGreaterThanOrEqual(count, 10)

        let client = IOSVaultClient(workspaceRoot: root.path, db: IndexDatabase(indexDBPath: dbPath))
        let entries = try await client.index()
        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains("vault/topics/repair-morphology-interface-control/00-overview.md"))
        XCTAssertTrue(paths.contains("vault/papers/kuipers-how-to-be-a-cell-phone-repair-technician-2015.md"))
        XCTAssertTrue(paths.contains("vault/papers/yu-water-resistant-smartphone-technologies-2019.md"))
        XCTAssertTrue(entries.contains { $0.type == .book })
        XCTAssertTrue(entries.contains { $0.type == .chapter })
        XCTAssertTrue(entries.contains { $0.type == .author })
        XCTAssertTrue(entries.contains { $0.author.contains("Joel C. Kuipers") })

        let text = try await client.entryText(path: "vault/topics/repair-morphology-interface-control/00-overview.md")
        XCTAssertTrue(text.contains("控制接口"))

        let sessionData = try Data(contentsOf: SessionFile.url(workspaceRoot: root.path))
        let session = try JSONDecoder().decode(SessionSnapshot.self, from: sessionData)
        XCTAssertEqual(session.spaces.first?.name, "阿尔冯斯")
        XCTAssertEqual(session.spaces.first?.activePath, "vault/topics/repair-morphology-interface-control/00-overview.md")
        #else
        throw XCTSkip("Demo vault is only compiled for DEBUG simulator builds.")
        #endif
    }
}
