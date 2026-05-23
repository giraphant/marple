import Testing
import Foundation
@testable import MarpleKit

@Suite struct VaultConfigTests {
    private func tempRepo(_ json: String?) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marple-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let json {
            try json.write(to: dir.appendingPathComponent("marple.config.json"),
                           atomically: true, encoding: .utf8)
        }
        return dir.path
    }

    @Test func resolvesWorkspaceAndVault() throws {
        let repo = try tempRepo(#"{"workspaceRoot": "/ws/root"}"#)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let paths = try resolveVaultPaths(repoRoot: repo)
        #expect(paths.workspaceRoot == "/ws/root")
        #expect(paths.vaultDir == "/ws/root/vault")
        #expect(paths.repoRoot == repo)
    }

    @Test func missingConfigThrows() throws {
        let repo = try tempRepo(nil)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(throws: VaultPathsError.self) { try resolveVaultPaths(repoRoot: repo) }
    }

    @Test func badJSONThrows() throws {
        let repo = try tempRepo("not json")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(throws: VaultPathsError.self) { try resolveVaultPaths(repoRoot: repo) }
    }
}
