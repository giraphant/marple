import Foundation

/// Seam for "find documents semantically". The GUI (`AppModel`) depends on this
/// protocol; the MLX-backed implementation lives in MarpleEmbeddings and is
/// injected at boot, so `AppModel` never imports the heavy embedding stack —
/// same separation as `VaultClient`.
public protocol SemanticBackend: Sendable {
    /// Up to `topK` (workspace-relative path, cosine score) matches, best first.
    func search(_ query: String, topK: Int) async throws -> [(path: String, score: Double)]
}

public enum SemanticBackendError: Error, Equatable {
    case indexMissing(String)
}
