import Testing
import Foundation
import MarpleKit
import MarpleEmbeddings

/// Validates the MLX embedder against the committed Python/MLX oracle. Gated on
/// MARPLE_RUN_MLX_EMBED because it downloads a model and needs the GPU:
///   MARPLE_RUN_MLX_EMBED=1 swift test --filter MLXTextEmbedderTests
/// The fixture stays pinned to its recorded model/dimension so default-model
/// changes do not make this implementation check download a new oracle.
private struct EmbedOracle: Decodable {
    struct Case: Decodable { let text: String; let vector: [Float] }
    let model: String
    let dim: Int
    let cases: [Case]
}

private func dot(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

@Suite struct MLXTextEmbedderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_RUN_MLX_EMBED"] != nil))
    func mlxEmbeddingsMatchOracle() async throws {
        let oracleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/qwen3-embedding-0.6B-oracle.json")
        let oracle = try JSONDecoder().decode(EmbedOracle.self, from: Data(contentsOf: oracleURL))

        let embedder = try await MLXTextEmbedder(
            modelId: "mlx-community/Qwen3-Embedding-0.6B-8bit",
            dimension: oracle.dim)
        #expect(embedder.dimension == oracle.dim)

        let vecs = try await embedder.embed(oracle.cases.map(\.text))
        #expect(vecs.count == oracle.cases.count)

        for (i, c) in oracle.cases.enumerated() {
            #expect(vecs[i].count == oracle.dim)
            let cos = dot(vecs[i], c.vector)   // both unit-norm ⇒ cosine == dot
            #expect(cos >= 0.97, "low cosine \(cos) for \(c.text.debugDescription)")
        }
    }
}
