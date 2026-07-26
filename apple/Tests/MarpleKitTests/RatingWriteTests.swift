import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

/// The vault schema types `rating` as an integer; the inspector used to write
/// `rating: ★★★★`, which fails schema conformance.
@Suite struct RatingWriteTests {
    @MainActor
    @Test func setRatingWritesInteger() async throws {
        let path = "vault/papers/p.md"
        let doc = Entry(path: path, type: .paper, title: "Paper", author: [],
                        year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let client = StubVaultClient(entries: [doc],
                                     texts: [path: "---\ntype: paper\n---\n\n# Paper\n"])
        let model = AppModel(client: client)
        await model.loadIndex()
        await model.open(path)

        await model.setRating(4)
        #expect(client.writeLog.last?.text.contains("rating: 4") == true)
        #expect(client.writeLog.last?.text.contains("★") == false)
    }
}
