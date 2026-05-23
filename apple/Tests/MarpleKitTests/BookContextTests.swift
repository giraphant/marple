import Testing
@testable import MarpleKit

@Suite struct BookContextTests {
    func mk(_ path: String, _ type: String, title: String? = nil, book: String? = nil) -> Entry {
        Entry(path: path, type: EntryType(rawValue: type), title: title, author: nil,
              year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false, book: book)
    }

    @Test func gathersOverviewAndChaptersFromChapter() {
        let ov = mk("vault/books/smith-2020/00-overview.md", "book-overview", title: "Smith 2020")
        let c2 = mk("vault/books/smith-2020/ch02.md", "chapter-summary", title: "Two", book: "smith-2020")
        let c1 = mk("vault/books/smith-2020/ch01.md", "chapter-summary", title: "One", book: "smith-2020")
        let other = mk("vault/papers/p.md", "paper-analysis")
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
        let ov = mk("vault/books/smith-2020/00-overview.md", "book-overview")
        let c1 = mk("vault/books/smith-2020/ch01.md", "chapter-summary", book: "smith-2020")
        let ctx = bookContext(for: ov, in: [ov, c1])
        #expect(ctx?.slug == "smith-2020")
        #expect(ctx?.chapters.map(\.path) == ["vault/books/smith-2020/ch01.md"])
    }

    @Test func nilForNonBookEntry() {
        let p = mk("vault/papers/p.md", "paper-analysis")
        #expect(bookContext(for: p, in: [p]) == nil)
    }

    @Test func overviewWithNoChaptersStillReturns() {
        let ov = mk("vault/books/solo-2021/00-overview.md", "book-overview")
        let ctx = bookContext(for: ov, in: [ov])
        #expect(ctx?.overview?.path == ov.path)
        #expect(ctx?.chapters.isEmpty == true)
    }

    @Test func chapterWithMissingOverview() {
        let c1 = mk("vault/books/x-2019/ch01.md", "chapter-summary", book: "x-2019")
        let ctx = bookContext(for: c1, in: [c1])
        #expect(ctx?.overview == nil)
        #expect(ctx?.chapters.map(\.path) == ["vault/books/x-2019/ch01.md"])
    }

    @Test func doesNotMixOtherBooks() {
        let aOv = mk("vault/books/a-2020/00-overview.md", "book-overview")
        let aCh = mk("vault/books/a-2020/ch01.md", "chapter-summary", book: "a-2020")
        let bCh = mk("vault/books/b-2020/ch01.md", "chapter-summary", book: "b-2020")
        let ctx = bookContext(for: aCh, in: [aOv, aCh, bCh])
        #expect(ctx?.overview?.path == aOv.path)
        #expect(ctx?.chapters.map(\.path) == ["vault/books/a-2020/ch01.md"])
    }
}
