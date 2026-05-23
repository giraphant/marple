import Foundation
import MLX
import MLXEmbedders
import MarpleKit
import Tokenizers

/// `TextEmbedder` backed by MLX (Apple-Silicon GPU) via MLXEmbedders' native
/// Qwen3 embedding model. Prototype on Qwen3-Embedding-0.6B now; swap `modelId`
/// for the 8B variant on the new Mac with no call-site changes (the seam).
///
/// One text at a time (batch=1, no padding) so last-token pooling picks the
/// real final token — MLXEmbedders' `.last` pooling is literally
/// `hiddenStates[..., -1, ...]`, which a padded batch would corrupt. Throughput
/// optimization (true batching with a mask) is a later refinement.
public actor MLXTextEmbedder: TextEmbedder {
    public nonisolated let dimension: Int
    private let container: ModelContainer

    public init(
        modelId: String = "mlx-community/Qwen3-Embedding-0.6B-8bit",
        dimension: Int = 1024
    ) async throws {
        self.dimension = dimension
        self.container = try await MLXEmbedders.loadModelContainer(
            configuration: ModelConfiguration.configuration(id: modelId))
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        await container.perform { (model, tokenizer, _) in
            let pooling = Pooling(strategy: .last)
            return texts.map { text in
                let ids = tokenizer.encode(text: text, addSpecialTokens: true)
                let input = MLXArray(ids).reshaped([1, ids.count])
                let output = model(
                    input, positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
                let pooled = pooling(output, normalize: true)
                pooled.eval()
                return pooled[0].asArray(Float.self)
            }
        }
    }
}
