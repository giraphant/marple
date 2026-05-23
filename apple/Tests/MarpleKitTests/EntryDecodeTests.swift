import Foundation
import Testing
@testable import MarpleKit

@Suite struct EntryDecodeTests {
    func decode(_ json: String) throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: Data(json.utf8))
    }

    @Test func testDecodesNumberYearAndRating() throws {
        let entries = try decode("""
        [{"path":"vault/p/a.md","type":"paper-analysis","title":"A",
          "author":"Smith","year":2019,"rating_score":3.0,
          "themes":["x","y"],"preview":"hi","has_pdf":true}]
        """)
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.type == .paperAnalysis)
        #expect(e.year == "2019")
        #expect(e.ratingScore == 3.0)
        #expect(e.themes == ["x", "y"])
        #expect(e.hasPDF)
    }

    @Test func testToleratesStringYearNullThemesMissingPdf() throws {
        let entries = try decode("""
        [{"path":"vault/n/b.md","type":"note","title":null,"author":null,
          "year":"forthcoming","rating_score":0,"themes":null,"preview":""}]
        """)
        let e = entries[0]
        #expect(e.type == .note)
        #expect(e.title == nil)
        #expect(e.year == "forthcoming")
        #expect(e.themes == [])
        #expect(!e.hasPDF)
    }
}
