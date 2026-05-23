import Foundation

/// The paths the app needs to boot. `workspaceRoot`/`vaultDir` come from the
/// user-picked library folder.
public struct VaultPaths: Sendable, Equatable {
    public let workspaceRoot: String
    public let vaultDir: String
    public init(workspaceRoot: String, vaultDir: String) {
        self.workspaceRoot = workspaceRoot; self.vaultDir = vaultDir
    }
}

public enum VaultPathsError: Error, Equatable {
    /// The picked folder is neither a workspace (no `vault/` inside) nor a `vault/`.
    case noVault(String)
}

/// Normalize a user-picked folder into `(workspaceRoot, vaultDir)`. Accepts either
/// the workspace folder (contains `vault/`) or the `vault/` folder itself.
public func resolveWorkspace(pickedPath: String,
                             fileManager: FileManager = .default) throws -> (workspaceRoot: String, vaultDir: String) {
    let picked = URL(fileURLWithPath: pickedPath).standardizedFileURL
    var isDir: ObjCBool = false
    let vaultInside = picked.appendingPathComponent("vault")
    if fileManager.fileExists(atPath: vaultInside.path, isDirectory: &isDir), isDir.boolValue {
        return (picked.path, vaultInside.path)
    }
    if picked.lastPathComponent == "vault" {
        return (picked.deletingLastPathComponent().path, picked.path)
    }
    throw VaultPathsError.noVault(pickedPath)
}
