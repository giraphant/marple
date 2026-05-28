import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct InspectorMetadataRowsTests {
    @Test func bookRowsUseCanonicalMetadataOrderAndOmitTitle() {
        let entry = Entry(
            path: "vault/books/book.md",
            type: .book,
            title: "The Long Title Should Stay In Reader",
            author: ["Lewis Mumford"],
            year: "1934",
            ratingScore: 4,
            themes: ["technology"],
            preview: "",
            hasPDF: false,
            source: "legacy source",
            topic: "legacy topic",
            doi: "10.1234/book-doi",
            publisher: "Harcourt Brace",
            isbn: "978-0-262-13472-9",
            category: "monograph"
        )

        #expect(inspectorInfoRows(for: entry) == [
            .authors,
            .readOnlyScalar(label: "年份", value: "1934", copyValue: nil),
            .readOnlyScalar(label: "出版", value: "Harcourt Brace", copyValue: nil),
            .readOnlyScalar(label: "类型", value: "专著", copyValue: "monograph"),
            .identifier(label: "ISBN", displayValue: "978…4729", fullValue: "978-0-262-13472-9"),
            .rating,
        ])
    }

    @Test func bookRowsUseDoiOnlyWhenIsbnIsMissing() {
        let entry = Entry(
            path: "vault/books/book.md",
            type: .book,
            title: "Book",
            author: ["Author"],
            year: "2020",
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false,
            doi: "10.7551/mitpress/11866.001.0001",
            publisher: "MIT Press",
            isbn: nil,
            category: "edited volume"
        )

        let rows = inspectorInfoRows(for: entry)
        #expect(rows.contains(.readOnlyScalar(label: "类型", value: "编著", copyValue: "edited volume")))
        #expect(rows.contains(
            .identifier(
                label: "DOI",
                displayValue: "10.7551/mit…",
                fullValue: "10.7551/mitpress/11866.001.0001"
            )
        ))
    }

    @Test func paperRowsUseCanonicalBibliographicOrder() {
        let entry = Entry(
            path: "vault/papers/paper.md",
            type: .paper,
            title: "Paper",
            author: ["Alice"],
            year: "2024",
            ratingScore: 3,
            themes: ["repair"],
            preview: "",
            hasPDF: false,
            source: "legacy source",
            topic: "legacy topic",
            journal: "Journal of Repair Studies",
            doi: "10.1234/paper"
        )

        #expect(inspectorInfoRows(for: entry) == [
            .authors,
            .readOnlyScalar(label: "年份", value: "2024", copyValue: nil),
            .readOnlyScalar(label: "期刊", value: "Journal of Repair Studies", copyValue: nil),
            .identifier(label: "DOI", displayValue: "10.1234/pap…", fullValue: "10.1234/paper"),
            .rating,
        ])
    }

    @Test func paperRowsFallBackToSourceWhenJournalIsMissing() {
        let entry = Entry(
            path: "vault/papers/paper.md",
            type: .paper,
            title: "Paper",
            author: ["Alice"],
            year: "2024",
            ratingScore: 3,
            themes: [],
            preview: "",
            hasPDF: false,
            source: "legacy source"
        )

        #expect(inspectorInfoRows(for: entry).contains(
            .readOnlyScalar(label: "期刊", value: "legacy source", copyValue: nil)
        ))
    }

    @Test func chapterRowsResolveBookSlugToBookTitleAndOmitTopic() {
        let entry = Entry(
            path: "vault/books/abbott-masking-in-the-pandemic-2023/ch01.md",
            type: .chapter,
            title: "Chapter",
            author: ["Alice"],
            year: "2024",
            ratingScore: 2,
            themes: [],
            preview: "",
            hasPDF: false,
            book: "abbott-masking-in-the-pandemic-2023",
            topic: "legacy topic"
        )
        let book = Entry(
            path: "vault/books/abbott-masking-in-the-pandemic-2023/00-overview.md",
            type: .book,
            title: "Masking in the Pandemic",
            author: ["Abbott"],
            year: "2023",
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false
        )

        #expect(inspectorInfoRows(for: entry, in: [entry, book]) == [
            .authors,
            .readOnlyScalar(label: "年份", value: "2024", copyValue: nil),
            .readOnlyScalar(label: "书籍", value: "Masking in the Pandemic", copyValue: "abbott-masking-in-the-pandemic-2023"),
            .rating,
        ])
    }

    @Test func authorRowsOnlyShowRating() {
        let entry = Entry(
            path: "vault/authors/alice.md",
            type: .author,
            title: "Alice",
            author: [],
            year: nil,
            ratingScore: 5,
            themes: ["repair"],
            preview: "",
            hasPDF: false
        )

        #expect(inspectorInfoRows(for: entry) == [.rating])
    }

    @Test func topicRowsShowKindAndTopicWithoutRating() {
        let entry = Entry(
            path: "vault/topics/repair.md",
            type: .topic,
            title: nil,
            author: [],
            year: nil,
            ratingScore: 4,
            themes: [],
            preview: "",
            hasPDF: false,
            topic: "repair",
            kind: "resources"
        )

        #expect(inspectorInfoRows(for: entry) == [
            .readOnlyScalar(label: "类型", value: "资源", copyValue: "resources"),
            .readOnlyScalar(label: "专题", value: "repair", copyValue: nil),
        ])
    }

    @Test func journalRowsShowKindAndJournal() {
        let entry = Entry(
            path: "vault/journals/ajs.md",
            type: .journal,
            title: nil,
            author: [],
            year: nil,
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false,
            kind: "overview",
            journal: "American Journal of Sociology"
        )

        #expect(inspectorInfoRows(for: entry) == [
            .readOnlyScalar(label: "类型", value: "概览", copyValue: "overview"),
            .readOnlyScalar(label: "期刊", value: "American Journal of Sociology", copyValue: nil),
        ])
    }

    @Test func noteRowsResolveAnnotationPathToEntryTitle() {
        let entry = Entry(
            path: "vault/notes/note.md",
            type: .note,
            title: "Note",
            author: [],
            year: nil,
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false,
            annotates: "vault/books/book/ch01.md",
            created: "2026-05-27"
        )
        let target = Entry(
            path: "vault/books/book/ch01.md",
            type: .chapter,
            title: "第一章 维修与社会",
            author: ["Alice"],
            year: "2024",
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false
        )

        #expect(inspectorInfoRows(for: entry, in: [entry, target]) == [
            .readOnlyScalar(label: "创建", value: "2026-05-27", copyValue: nil),
            .readOnlyScalar(label: "标注", value: "第一章 维修与社会", copyValue: "vault/books/book/ch01.md"),
        ])
    }

    @Test func imageRowsOnlyShowCanonicalTitle() {
        let entry = Entry(
            path: "vault/images/image.md",
            type: .image,
            title: "Diagram",
            author: ["legacy author"],
            year: nil,
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false,
            source: "legacy source",
            topic: "legacy topic"
        )

        #expect(inspectorInfoRows(for: entry) == [
            .editableScalar(label: "名称", value: "Diagram", action: .title),
        ])
    }
}
