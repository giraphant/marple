import Foundation
import MarpleKit

/// MLX-backed `SemanticBackend`. Lazily loads the embedding model + the on-disk
/// vector index on the FIRST query (the actor serializes that init), so launching
/// the app costs nothing until a 深度 search actually runs — and the model only
/// resides in memory once semantic search has been used.
public actor MLXSemanticBackend: SemanticBackend {
    private let dir: URL
    private let modelId: String
    private var searcher: SemanticSearcher?

    public init(dir: URL, modelId: String = "mlx-community/Qwen3-Embedding-8B-4bit-DWQ") {
        self.dir = dir
        self.modelId = modelId
    }

    public func search(_ query: String, topK: Int) async throws -> [(path: String, score: Double)] {
        let s = try await ensureSearcher()
        return try await s.search(query, topK: topK).map { (path: $0.path, score: Double($0.score)) }
    }

    private func ensureSearcher() async throws -> SemanticSearcher {
        if let searcher { return searcher }
        guard let loaded = try VectorIndexIO.read(dir: dir) else {
            throw SemanticBackendError.indexMissing(dir.path)
        }
        let embedder = try await MLXTextEmbedder(modelId: modelId)
        let s = SemanticSearcher(embedder: embedder, store: loaded.store)
        searcher = s
        return s
    }
}
