import Testing
import Foundation
@testable import MarpleKit

@Suite struct CardMetricsTests {
    private func entry(preview: String, title: String = "Title", themes: [String] = []) -> Entry {
        Entry(path: "p.md", type: .paper, title: title, author: ["A"], year: "2020",
              ratingScore: 5, themes: themes, preview: preview, hasPDF: false)
    }

    @Test func longerPreviewIsTaller() {
        let short = CardMetrics.estimatedHeight(for: entry(preview: "短"))
        let long = CardMetrics.estimatedHeight(for: entry(preview: String(repeating: "字", count: 600)))
        #expect(long > short)
    }

    @Test func previewIsClamped() {
        let huge = CardMetrics.estimatedHeight(for: entry(preview: String(repeating: "x", count: 100_000)))
        #expect(huge < 400) // one giant entry must not dominate a column
    }

    @Test func emptyPreviewStillHasChrome() {
        #expect(CardMetrics.estimatedHeight(for: entry(preview: "")) > 40)
    }

    @Test func imageEntriesReserveThumbnailHeight() {
        let image = Entry(path: "vault/images/loop/image.md", type: .image, title: "Loop",
                          author: [], year: nil, ratingScore: 0, themes: [],
                          preview: "", hasPDF: false)
        #expect(CardMetrics.estimatedHeight(for: image) >= 280)
    }
}
