import Foundation
import Tokenizers

/// Thin wrapper over swift-transformers' tokenizer — the first real building
/// block under `TextEmbedder`. Loading is from a local model folder (offline,
/// deterministic) holding `tokenizer.json` + `tokenizer_config.json`.
///
/// Why this matters: byte-level BPE on CJK is the easiest place for a Swift
/// reimplementation to silently disagree with the reference tokenizer, which
/// would corrupt every embedding. `HFTokenizerAlignmentTests` pins our output
/// to the HF reference so a drift here fails loudly.
public struct HFTokenizer: Sendable {
    private let tokenizer: Tokenizer

    public init(modelFolder: URL) async throws {
        self.tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder)
    }

    public func encode(_ text: String, addSpecialTokens: Bool = false) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
}
