import Foundation

/// The on-disk repo config the sidecar also reads (MARPLE_ROOT/marple.config.json).
public struct MarpleConfig: Codable, Sendable, Equatable {
    public let workspaceRoot: String
}

public struct VaultPaths: Sendable, Equatable {
    public let repoRoot: String
    public let workspaceRoot: String
    public let vaultDir: String
}

public enum VaultPathsError: Error, Equatable {
    case missingConfig(String)
    case badConfig(String)
}

/// Resolve a chosen repo directory into the paths the app needs: `repoRoot` drives
/// the sidecar launch, `vaultDir` (= workspaceRoot/vault) is what the watcher tails.
/// Reads `repoRoot/marple.config.json` for `workspaceRoot`.
public func resolveVaultPaths(repoRoot: String,
                              fileManager: FileManager = .default) throws -> VaultPaths {
    let configPath = (repoRoot as NSString).appendingPathComponent("marple.config.json")
    guard fileManager.fileExists(atPath: configPath) else {
        throw VaultPathsError.missingConfig(configPath)
    }
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: configPath)) }
    catch { throw VaultPathsError.badConfig("\(error)") }
    let cfg: MarpleConfig
    do { cfg = try JSONDecoder().decode(MarpleConfig.self, from: data) }
    catch { throw VaultPathsError.badConfig("\(error)") }
    let vault = (cfg.workspaceRoot as NSString).appendingPathComponent("vault")
    return VaultPaths(repoRoot: repoRoot, workspaceRoot: cfg.workspaceRoot, vaultDir: vault)
}
