import Foundation
import MLX
import MLXEmbedders
import MarpleKit
import Tokenizers

/// `TextEmbedder` backed by MLX (Apple-Silicon GPU) via MLXEmbedders' native
/// Qwen3 embedding model. The default is the 8B 4-bit model used for Marple's
/// local semantic search.
///
/// One text at a time (batch=1, no padding) so last-token pooling picks the
/// real final token — MLXEmbedders' `.last` pooling is literally
/// `hiddenStates[..., -1, ...]`, which a padded batch would corrupt. Throughput
/// optimization (true batching with a mask) is a later refinement.
public actor MLXTextEmbedder: TextEmbedder {
    public nonisolated let dimension: Int
    private let container: ModelContainer
    private let maxTokens: Int

    public init(
        modelId: String = SemanticIndexDefaults.modelID,
        dimension: Int = 4096,
        maxTokens: Int = 32_768
    ) async throws {
        self.dimension = dimension
        self.maxTokens = maxTokens
        self.container = try await MLXEmbedders.loadModelContainer(
            configuration: ModelConfiguration.configuration(id: modelId))
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        let cap = maxTokens
        return await container.perform { (model, tokenizer, _) in
            let pooling = Pooling(strategy: .last)
            return texts.map { text in
                // Truncate to cap (matches the reference max_length); .last then
                // pools the final kept token, so a long doc embeds its lead.
                let ids = Array(tokenizer.encode(text: text, addSpecialTokens: true).prefix(cap))
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
