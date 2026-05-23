import Testing
import Foundation
@testable import MarpleKit

@Suite struct VaultConfigTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marple-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func resolvesWorkspaceFromFolderContainingVault() throws {
        let ws = try tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(
            at: ws.appendingPathComponent("vault"), withIntermediateDirectories: true)
        let r = try resolveWorkspace(pickedPath: ws.path)
        #expect(r.workspaceRoot == ws.standardizedFileURL.path)
        #expect(r.vaultDir == ws.appendingPathComponent("vault").standardizedFileURL.path)
    }

    @Test func resolvesWorkspaceWhenVaultItselfPicked() throws {
        let ws = try tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let vault = ws.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let r = try resolveWorkspace(pickedPath: vault.path)
        #expect(r.workspaceRoot == ws.standardizedFileURL.path)
        #expect(r.vaultDir == vault.standardizedFileURL.path)
    }

    @Test func resolveWorkspaceThrowsWhenNoVault() throws {
        let plain = try tempDir()
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(throws: VaultPathsError.self) { try resolveWorkspace(pickedPath: plain.path) }
    }
}
