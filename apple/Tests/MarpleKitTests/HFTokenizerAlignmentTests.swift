import Testing
import Foundation
@testable import MarpleKit

/// Proves swift-transformers reproduces the HF reference tokenizer exactly for
/// CJK text (the byte-level-BPE drift risk). Gated on an env-provided fixture
/// dir so normal `swift test` stays hermetic and the ~11MB tokenizer.json is
/// never committed.
///
/// Run it:
///   MARPLE_TOKENIZER_FIXTURE_DIR=/path/to/fixture \
///     swift test --filter HFTokenizerAlignmentTests
///
/// The fixture dir must hold: tokenizer.json, tokenizer_config.json, and
/// ground_truth.json — the latter produced by the HF `tokenizers` lib via
/// `encode(text, add_special_tokens=False).ids` on the same tokenizer.json.
private enum Fixture {
    static var dir: URL? {
        ProcessInfo.processInfo.environment["MARPLE_TOKENIZER_FIXTURE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

private struct GroundTruth: Decodable {
    struct Case: Decodable { let text: String; let ids_no_special: [Int] }
    let model: String
    let cases: [Case]
}

@Suite struct HFTokenizerAlignmentTests {
    @Test(.enabled(if: Fixture.dir != nil))
    func swiftTokensMatchHFReference() async throws {
        let dir = try #require(Fixture.dir)
        let gtURL = dir.appendingPathComponent("ground_truth.json")
        let gt = try JSONDecoder().decode(GroundTruth.self, from: Data(contentsOf: gtURL))
        #expect(!gt.cases.isEmpty)

        let tok = try await HFTokenizer(modelFolder: dir)
        for c in gt.cases {
            let got = tok.encode(c.text, addSpecialTokens: false)
            #expect(got == c.ids_no_special,
                    "tokenizer drift for \(c.text.debugDescription): swift=\(got) ref=\(c.ids_no_special)")
        }
    }
}
