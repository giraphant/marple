import Testing
@testable import MarpleKit

@Suite struct BookContextTests {
    /// Test factory — accepts a legacy joined-string `author` for terseness;
    /// `splitAuthors` converts it to the canonical `[String]` on construction.
    func mk(_ path: String, _ type: String, title: String? = nil, author: String? = nil,
            year: String? = nil, book: String? = nil, hasPDF: Bool = false,
            pdfSlug: String? = nil, source: String? = nil, doi: String? = nil) -> Entry {
        Entry(path: path, type: EntryType(rawValue: type), title: title,
              author: splitAuthors(author),
              year: year, ratingScore: 0, themes: [], preview: "", hasPDF: hasPDF,
              pdfSlug: pdfSlug, source: source, book: book, doi: doi)
    }

    @Test func gathersOverviewAndChaptersFromChapter() {
        let ov = mk("vault/books/smith-2020/00-overview.md", "book", title: "Smith 2020")
        let c2 = mk("vault/books/smith-2020/ch02.md", "chapter", title: "Two", book: "smith-2020")
        let c1 = mk("vault/books/smith-2020/ch01.md", "chapter", title: "One", book: "smith-2020")
        let other = mk("vault/papers/p.md", "paper")
        let entries = [ov, c2, c1, other]

        let ctx = bookContext(for: c1, in: entries)
        #expect(ctx?.slug == "smith-2020")
        #expect(ctx?.overview?.path == ov.path)
        #expect(ctx?.chapters.map(\.path) == [
            "vault/books/smith-2020/ch01.md",
            "vault/books/smith-2020/ch02.md",
        ])  // path-sorted, not input order
    }

    @Test func gathersFromOverviewByPathSlug() {
        let ov = mk("vault/books/smith-2020/00-overview.md", "book")
        let c1 = mk("vault/books/smith-2020/ch01.md", "chapter", book: "smith-2020")
        let ctx = bookContext(for: ov, in: [ov, c1])
        #expect(ctx?.slug == "smith-2020")
        #expect(ctx?.chapters.map(\.path) == ["vault/books/smith-2020/ch01.md"])
    }

    @Test func nilForNonBookEntry() {
        let p = mk("vault/papers/p.md", "paper")
        #expect(bookContext(for: p, in: [p]) == nil)
    }

    @Test func overviewWithNoChaptersStillReturns() {
        let ov = mk("vault/books/solo-2021/00-overview.md", "book")
        let ctx = bookContext(for: ov, in: [ov])
        #expect(ctx?.overview?.path == ov.path)
        #expect(ctx?.chapters.isEmpty == true)
    }

    @Test func chapterWithMissingOverview() {
        let c1 = mk("vault/books/x-2019/ch01.md", "chapter", book: "x-2019")
        let ctx = bookContext(for: c1, in: [c1])
        #expect(ctx?.overview == nil)
        #expect(ctx?.chapters.map(\.path) == ["vault/books/x-2019/ch01.md"])
    }

    @Test func doesNotMixOtherBooks() {
        let aOv = mk("vault/books/a-2020/00-overview.md", "book")
        let aCh = mk("vault/books/a-2020/ch01.md", "chapter", book: "a-2020")
        let bCh = mk("vault/books/b-2020/ch01.md", "chapter", book: "b-2020")
        let ctx = bookContext(for: aCh, in: [aOv, aCh, bCh])
        #expect(ctx?.overview?.path == aOv.path)
        #expect(ctx?.chapters.map(\.path) == ["vault/books/a-2020/ch01.md"])
    }

    @Test func citationEntryForChapterFallsBackToOverviewWhenChapterHasNoCitationMetadata() {
        let ov = mk("vault/books/smith-2020/00-overview.md", "book",
                    title: "Smith Book", author: "Jane Smith", year: "2020")
        let ch = mk("vault/books/smith-2020/ch01.md", "chapter", title: "Chapter One", book: "smith-2020")
        #expect(citationEntry(for: ch, in: [ov, ch])?.path == ov.path)
    }

    @Test func citationEntryForChapterUsesChapterWhenItHasCitationMetadata() {
        let ov = mk("vault/books/smith-2020/00-overview.md", "book",
                    title: "Smith Book", author: "Jane Smith", year: "2020")
        let ch = mk("vault/books/smith-2020/ch01.md", "chapter", title: "Chapter One",
                    author: "Chapter Author", year: "2021", book: "smith-2020")
        #expect(citationEntry(for: ch, in: [ov, ch])?.path == ch.path)
    }

    @Test func pdfEntryForChapterFallsBackToOverviewWhenChapterHasNoPDF() {
        let ov = mk("vault/books/smith-2020/00-overview.md", "book",
                    hasPDF: true, pdfSlug: "smith-2020")
        let ch = mk("vault/books/smith-2020/ch01.md", "chapter", book: "smith-2020")
        #expect(pdfEntry(for: ch, in: [ov, ch])?.path == ov.path)
    }

    @Test func pdfEntryForChapterUsesChapterWhenItHasPDF() {
        let ov = mk("vault/books/smith-2020/00-overview.md", "book",
                    hasPDF: true, pdfSlug: "smith-2020")
        let ch = mk("vault/books/smith-2020/ch01.md", "chapter", book: "smith-2020",
                    hasPDF: true, pdfSlug: "smith-2020-ch01")
        #expect(pdfEntry(for: ch, in: [ov, ch])?.path == ch.path)
    }

    @Test func sourceSlugCandidatesForChapterPreferChapterThenOverview() {
        let ov = mk("vault/books/smith-2020/00-overview.md", "book", pdfSlug: "smith-2020")
        let ch = mk("vault/books/smith-2020/ch01.md", "chapter", book: "smith-2020",
                    pdfSlug: "smith-2020-ch01")
        #expect(sourceSlugCandidates(for: ch, in: [ov, ch]) == ["smith-2020-ch01", "smith-2020"])
    }

    @Test func sourceSlugCandidatesForBookDoNotRequirePDF() {
        let ov = mk("vault/books/smith-2020/00-overview.md", "book", pdfSlug: "smith-2020")
        #expect(sourceSlugCandidates(for: ov, in: [ov]) == ["smith-2020"])
    }
}
