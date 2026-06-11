import Testing
import Foundation
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
            journal: "Journal of Repair Studies",
            doi: "10.1234/paper"
        )
        let journal = Entry(
            path: "vault/journals/journal-of-repair-studies.md",
            type: .journal,
            title: "Repair Studies",
            author: [],
            year: nil,
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false,
            journal: "Journal of Repair Studies"
        )

        #expect(inspectorInfoRows(for: entry, in: [entry, journal]) == [
            .authors,
            .readOnlyScalar(label: "年份", value: "2024", copyValue: nil),
            .linkedScalar(
                label: "期刊",
                value: "Journal of Repair Studies",
                path: "vault/journals/journal-of-repair-studies.md",
                copyValue: "Journal of Repair Studies"
            ),
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
            book: "abbott-masking-in-the-pandemic-2023"
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
            hasPDF: false,
            publisher: "Beacon",
            isbn: "978-0-262-13472-9",
            category: "monograph"
        )

        let rows = inspectorInfoRows(for: entry, in: [entry, book])
        #expect(rows.prefix(3) == [
            .authors,
            .readOnlyScalar(label: "年份", value: "2024", copyValue: nil),
            .linkedScalar(
                label: "书籍",
                value: "Masking in the Pandemic",
                path: "vault/books/abbott-masking-in-the-pandemic-2023/00-overview.md",
                copyValue: "abbott-masking-in-the-pandemic-2023"
            ),
        ])
        #expect(rows.contains(.readOnlyScalar(label: "出版", value: "Beacon", copyValue: nil)))
        #expect(rows.contains(.readOnlyScalar(label: "类型", value: "专著", copyValue: "monograph")))
        #expect(rows.contains(.identifier(label: "ISBN", displayValue: "978…4729", fullValue: "978-0-262-13472-9")))
        #expect(rows.last == .rating)
    }

    @Test func bookTranslationRowLinksToDoubanAboveRating() {
        // A book whose ISBN resolves in the cndouban sidecar surfaces a "译本"
        // row linking to its Douban edition, directly above the rating (and below
        // 专题). ISBN matching is digits-only, so the dashed form still resolves.
        let entry = Entry(
            path: "vault/books/book.md",
            type: .book,
            title: "Engineering Rules",
            author: ["JoAnne Yates"],
            year: "2019",
            ratingScore: 0,
            themes: [],
            topics: ["iphone-screws"],
            preview: "",
            hasPDF: false,
            publisher: "Johns Hopkins University Press",
            isbn: "978-1-4214-2889-5",
            category: "monograph"
        )
        let topicPage = Entry(
            path: "vault/topics/iphone-screws/00-overview.md",
            type: .topic, title: "iPhone 螺丝", author: [], year: nil,
            ratingScore: 0, themes: [], preview: "", hasPDF: false
        )
        let localise = CnDoubanIndex(byISBN: [
            "9781421428895": .init(titleCn: "工程规则",
                                   doubanURL: "https://book.douban.com/subject/12345/"),
        ])

        let rows = inspectorInfoRows(for: entry, in: [entry, topicPage], localise: localise)
        // 专题 (chips) immediately followed by 译本, then rating last.
        #expect(rows.suffix(3) == [
            .chips(label: "专题", values: [
                InspectorInfoChip(title: "iPhone 螺丝",
                                  path: "vault/topics/iphone-screws/00-overview.md",
                                  copyValue: "iphone-screws"),
            ]),
            .linkedScalar(label: "译本", value: "工程规则",
                          path: "https://book.douban.com/subject/12345/",
                          copyValue: "https://book.douban.com/subject/12345/"),
            .rating,
        ])
    }

    @Test func chapterTranslationRowResolvesFromBookOverviewISBN() {
        // A chapter has no ISBN of its own; the 译本 row is resolved from its
        // parent book overview's ISBN, mirroring how 出版/类型/ISBN are sourced.
        let chapter = Entry(
            path: "vault/books/yates-engineering-rules-2019/ch01.md",
            type: .chapter, title: "Chapter", author: ["JoAnne Yates"], year: "2019",
            ratingScore: 0, themes: [], preview: "", hasPDF: false,
            book: "yates-engineering-rules-2019"
        )
        let book = Entry(
            path: "vault/books/yates-engineering-rules-2019/00-overview.md",
            type: .book, title: "Engineering Rules", author: ["JoAnne Yates"], year: "2019",
            ratingScore: 0, themes: [], preview: "", hasPDF: false,
            isbn: "9781421428895"
        )
        let localise = CnDoubanIndex(byISBN: [
            "9781421428895": .init(titleCn: "工程规则",
                                   doubanURL: "https://book.douban.com/subject/12345/"),
        ])

        let rows = inspectorInfoRows(for: chapter, in: [chapter, book], localise: localise)
        #expect(rows.contains(
            .linkedScalar(label: "译本", value: "工程规则",
                          path: "https://book.douban.com/subject/12345/",
                          copyValue: "https://book.douban.com/subject/12345/")
        ))
        #expect(rows.last == .rating)
    }

    @Test func translationRowOmittedWhenNoSidecarOrNoMatch() {
        // No sidecar → no 译本 row. ISBN not in the sidecar → no row either.
        let book = Entry(
            path: "vault/books/book.md", type: .book, title: "Untranslated",
            author: ["A"], year: "2010", ratingScore: 0, themes: [], preview: "",
            hasPDF: false, isbn: "9780000000000"
        )
        #expect(!inspectorInfoRows(for: book).contains { row in
            if case .linkedScalar(let label, _, _, _) = row { return label == "译本" }
            if case .readOnlyScalar(let label, _, _) = row { return label == "译本" }
            return false
        })
        let localise = CnDoubanIndex(byISBN: [
            "9781421428895": .init(titleCn: "工程规则", doubanURL: nil),
        ])
        #expect(!inspectorInfoRows(for: book, in: [book], localise: localise).contains { row in
            if case .readOnlyScalar(let label, _, _) = row { return label == "译本" }
            return false
        })
    }

    @Test func translationRowShowsPlainTextWhenNoDoubanURL() {
        // A resolved edition without a usable Douban URL renders as plain text.
        let book = Entry(
            path: "vault/books/book.md", type: .book, title: "Book",
            author: ["A"], year: "2010", ratingScore: 0, themes: [], preview: "",
            hasPDF: false, isbn: "9781421428895"
        )
        let localise = CnDoubanIndex(byISBN: [
            "9781421428895": .init(titleCn: "中文书名", doubanURL: nil),
        ])
        let rows = inspectorInfoRows(for: book, in: [book], localise: localise)
        #expect(rows.contains(.readOnlyScalar(label: "译本", value: "中文书名", copyValue: nil)))
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

    @Test func topicRowsShowKindWithoutRatingOrTopicScalar() {
        // Schema 0.4.0: the singular `topic` scalar is gone; a topic page's
        // identity is its directory slug + H1, so only `kind` surfaces here.
        let entry = Entry(
            path: "vault/topics/repair/00-overview.md",
            type: .topic,
            title: "维修",
            author: [],
            year: nil,
            ratingScore: 4,
            themes: [],
            preview: "",
            hasPDF: false,
            kind: "resources"
        )

        #expect(inspectorInfoRows(for: entry) == [
            .readOnlyScalar(label: "类型", value: "资源", copyValue: "resources"),
        ])
    }

    @Test func topicsMembershipRowResolvesSlugsToTopicTitlesBeforeRating() {
        // A paper declaring `topics:` membership shows a read-only "专题"
        // chip row, with each slug resolved to its topic page's title when loaded
        // (falling back to the raw slug), inserted just above the rating row.
        let paper = Entry(
            path: "vault/papers/p.md",
            type: .paper,
            title: "P",
            author: ["Alice"],
            year: "2024",
            ratingScore: 3,
            themes: [],
            topics: ["smartphone-repair", "unknown-slug"],
            preview: "",
            hasPDF: false
        )
        let topicPage = Entry(
            path: "vault/topics/smartphone-repair/00-overview.md",
            type: .topic,
            title: "智能手机维修",
            author: [],
            year: nil,
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false
        )

        #expect(inspectorInfoRows(for: paper, in: [paper, topicPage]) == [
            .authors,
            .readOnlyScalar(label: "年份", value: "2024", copyValue: nil),
            .chips(label: "专题", values: [
                InspectorInfoChip(
                    title: "智能手机维修",
                    path: "vault/topics/smartphone-repair/00-overview.md",
                    copyValue: "smartphone-repair"
                ),
                InspectorInfoChip(title: "unknown-slug", path: nil, copyValue: "unknown-slug"),
            ]),
            .rating,
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

    /// QUA-175: images expose the editable descriptive fields (creator folds
    /// into `author`, date into `created`) plus index-derived read-only
    /// dimensions / file size when present.
    @Test func imageRowsShowDescriptiveAndDerivedFields() {
        let entry = Entry(
            path: "vault/images/image.md",
            type: .image,
            title: "Diagram",
            author: ["Henry Maudslay"],
            year: nil,
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false,
            source: "https://example.org/diagram",
            created: "2024-11-08",
            width: 3024, height: 4032, fileSize: 123_456
        )

        #expect(inspectorInfoRows(for: entry) == [
            .editableScalar(label: "名称", value: "Diagram", action: .title),
            .authors,
            .editableScalar(label: "日期", value: "2024-11-08", action: .imageDate),
            .editableScalar(label: "来源", value: "https://example.org/diagram", action: .source),
            .readOnlyScalar(label: "尺寸", value: "3024 × 4032", copyValue: "3024×4032"),
            .readOnlyScalar(label: "大小", value: ByteCountFormatter.string(fromByteCount: 123_456, countStyle: .file), copyValue: nil),
            .rating,
        ])
    }

    /// Without index-derived dims the read-only rows are omitted entirely.
    @Test func imageRowsOmitDerivedFieldsWhenAbsent() {
        let entry = Entry(
            path: "vault/images/image.md",
            type: .image,
            title: "Diagram",
            author: [],
            year: nil,
            ratingScore: 0,
            themes: [],
            preview: "",
            hasPDF: false
        )

        #expect(inspectorInfoRows(for: entry) == [
            .editableScalar(label: "名称", value: "Diagram", action: .title),
            .authors,
            .editableScalar(label: "日期", value: nil, action: .imageDate),
            .editableScalar(label: "来源", value: nil, action: .source),
            .rating,
        ])
    }
}
