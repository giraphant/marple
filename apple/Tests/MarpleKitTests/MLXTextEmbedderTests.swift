import Testing
import Foundation
import MarpleKit
import MarpleEmbeddings

/// Validates the MLX embedder against the committed Python/MLX oracle. Gated on
/// MARPLE_RUN_MLX_EMBED because it downloads a ~600MB model and needs the GPU:
///   MARPLE_RUN_MLX_EMBED=1 swift test --filter MLXTextEmbedderTests
/// Swift loads 8-bit weights vs the oracle's full-precision vectors, so we check
/// cosine ≥ 0.97 (quantization gap), not exact equality.
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

        let embedder = try await MLXTextEmbedder()
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
