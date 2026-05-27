import Foundation

/// Embeds a query (with Qwen3-Embedding's asymmetric instruct prefix — queries
/// get the prefix, documents are embedded raw) and returns the top-K nearest
/// documents from a `VectorStore` by cosine.
public struct SemanticSearcher: Sendable {
    let embedder: any TextEmbedder
    let store: VectorStore

    public init(embedder: any TextEmbedder, store: VectorStore) {
        self.embedder = embedder
        self.store = store
    }

    public static let defaultTask =
        "Given a search query, retrieve relevant notes and documents from the library"
    public static let defaultMinimumScore: Float = 0.48

    public func search(_ query: String, topK: Int = 20,
                       minimumScore: Float = Self.defaultMinimumScore,
                       task: String = defaultTask
    ) async throws -> [(path: String, score: Float)] {
        let prompt = "Instruct: \(task)\nQuery:\(query)"
        let vec = try await embedder.embed(prompt)
        return store.topK(vec, k: topK).filter { $0.score >= minimumScore }
    }
}
