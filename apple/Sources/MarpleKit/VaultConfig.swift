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

/// Walk up from `start` until a directory contains `rust/Cargo.toml`; that's the
/// marple repo (needed only to `cargo run` the sidecar). Accepts a file or dir as
/// the start. Returns nil at the filesystem root with no match.
public func findRepoRoot(startingFrom start: String, fileManager: FileManager = .default) -> String? {
    var dir = URL(fileURLWithPath: start).standardizedFileURL
    while true {
        let marker = dir.appendingPathComponent("rust/Cargo.toml").path
        if fileManager.fileExists(atPath: marker) { return dir.path }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { return nil }   // reached "/"
        dir = parent
    }
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
