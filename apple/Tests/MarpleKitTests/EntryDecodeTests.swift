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

    @Test func testUnknownTypeBecomesOtherAndDoesNotFailArray() throws {
        // The real vault contains an entry with type "topic-reading-list", which
        // the reader doesn't model. One unknown type must NOT fail the whole
        // index decode — it should become .other and the array stays intact.
        let entries = try decode("""
        [{"path":"vault/t/r.md","type":"topic-reading-list","preview":"","rating_score":0},
         {"path":"vault/p/a.md","type":"paper-analysis","preview":"","rating_score":0}]
        """)
        #expect(entries.count == 2)
        #expect(entries[0].type == .other("topic-reading-list"))
        #expect(entries[1].type == .paperAnalysis)
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

    @Test func testDecodesBrowseFieldsForSortAndFilter() throws {
        let entries = try decode("""
        [{"path":"vault/p/a.md","type":"paper-analysis","title":"A","rating_score":0,
          "preview":"","mtime":1700000000000,"added":1690000000000,
          "source":"JSTOR","book":"Some Book","topic":"econ","doi":"10.1/x"}]
        """)
        let e = entries[0]
        #expect(e.mtime == 1700000000000)
        #expect(e.added == 1690000000000)
        #expect(e.source == "JSTOR")
        #expect(e.book == "Some Book")
        #expect(e.topic == "econ")
        #expect(e.doi == "10.1/x")
    }

    @Test func testDecodesBookCanonicalMetadataForInspector() throws {
        let entries = try decode("""
        [{"path":"vault/books/b.md","type":"book-overview","title":"B","rating_score":0,
          "preview":"","publisher":"MIT Press","isbn":"978-0-262-13472-9","category":"monograph"}]
        """)
        let e = entries[0]
        #expect(e.publisher == "MIT Press")
        #expect(e.isbn == "978-0-262-13472-9")
        #expect(e.category == "monograph")
    }

    @Test func testBrowseFieldsTolerateAbsence() throws {
        let entries = try decode("""
        [{"path":"vault/n/b.md","type":"note","preview":"","rating_score":0}]
        """)
        let e = entries[0]
        #expect(e.mtime == nil)
        #expect(e.added == nil)
        #expect(e.source == nil)
    }

    @Test func testDecodesLightweightCanonicalMetadataForInspector() throws {
        let entries = try decode("""
        [{"path":"vault/journals/ajs.md","type":"journal","preview":"","rating_score":0,
          "kind":"overview","journal":"American Journal of Sociology","created":"2026-05-27"}]
        """)
        let e = entries[0]
        #expect(e.type == .journal)
        #expect(e.kind == "overview")
        #expect(e.journal == "American Journal of Sociology")
        #expect(e.created == "2026-05-27")
    }

    @Test func testDecodesAnnotates() throws {
        let entries = try decode("""
        [{"path":"vault/notes/n.md","type":"note","themes":[],"preview":"","rating_score":0,
          "annotates":"vault/papers/p.md"}]
        """)
        #expect(entries[0].annotates == "vault/papers/p.md")
    }

    @Test func testAnnotatesAbsentIsNil() throws {
        let entries = try decode("""
        [{"path":"vault/papers/p.md","type":"paper-analysis","preview":"","rating_score":0}]
        """)
        #expect(entries[0].annotates == nil)
    }

    @Test func testShortTopicTypeUsesModeledTopic() throws {
        let entries = try decode("""
        [{"path":"vault/topics/repair.md","type":"topic","preview":"","rating_score":0,
          "topic":"repair","kind":"overview"}]
        """)
        #expect(entries[0].type == .topicSynthesis)
        #expect(entriesForPane(.type(.topicSynthesis), in: entries).map(\.path) == ["vault/topics/repair.md"])
    }

    @Test func testImageTypeIsModeled() {
        #expect(EntryType(rawValue: "image") == .image)
        #expect(EntryType.image.rawValue == "image")
        #expect(EntryType.image.label == "图片")
        #expect(EntryType.modeled.contains(.image))
    }

    @Test func testEntryWithUpdatesImageEditableMetadata() {
        let entry = Entry(path: "vault/images/loop/image.md", type: .image, title: "Old",
                          author: ["Alice"], year: nil, ratingScore: 0, themes: [],
                          preview: "", hasPDF: false)
        let updated = entry.with(title: .some("New"), author: ["Bob"])
        #expect(updated.title == "New")
        #expect(updated.author == ["Bob"])
    }

    @Test func testModeledTypesOrderAndLabels() {
        #expect(EntryType.modeled == [.paperAnalysis, .bookOverview, .authorProfile,
                                      .topicSynthesis, .journal, .chapterSummary, .note, .image])
        #expect(EntryType.paperAnalysis.label == "论文")
        #expect(EntryType.journal.label == "期刊")
        #expect(EntryType.note.label == "笔记")
        #expect(EntryType.image.label == "图片")
        #expect(EntryType.other("topic-reading-list").label == "topic-reading-list")
    }
}
