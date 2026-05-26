import Testing
@testable import MarpleKit

@Suite struct RelationsIndexTests {
    func mk(_ path: String, _ type: String, title: String? = nil, author: String? = nil,
            themes: [String] = [], rating: Double = 0, book: String? = nil,
            annotates: String? = nil) -> Entry {
        Entry(path: path, type: EntryType(rawValue: type), title: title, author: author,
              year: nil, ratingScore: rating, themes: themes, preview: "", hasPDF: false,
              book: book, annotates: annotates)
    }

    @Test func splitAuthorsSeparators() {
        #expect(splitAuthors("A, B") == ["A", "B"])
        #expect(splitAuthors("A and B") == ["A", "B"])
        #expect(splitAuthors("A & B") == ["A", "B"])
        #expect(splitAuthors("Kelly Fritsch, Anne McGuire") == ["Kelly Fritsch", "Anne McGuire"])
        #expect(splitAuthors(nil) == [])
        #expect(splitAuthors("") == [])
    }

    @Test func annotationsByTarget() {
        let p = mk("vault/papers/p.md", "paper-analysis")
        let n = mk("vault/notes/n.md", "note", annotates: "vault/papers/p.md")
        let entries = [p, n]
        let rel = relations(for: p, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.annotations.map(\.path) == ["vault/notes/n.md"])
    }

    @Test func chapterAnnotationsResolveToBookOverview() {
        let overview = mk("vault/books/smith-2020/00-overview.md", "book-overview")
        let chapter = mk("vault/books/smith-2020/ch01.md", "chapter-summary", book: "smith-2020")
        let note = mk("vault/notes/chapter-note.md", "note", annotates: "vault/books/smith-2020/ch01.md")
        let entries = [overview, chapter, note]
        let annotationIndex = buildAnnotationIndex(entries)

        #expect(annotationAnchor(for: chapter, in: entries).path == overview.path)
        #expect(annotationIndex[overview.path]?.map(\.path) == [note.path])
        #expect(annotationIndex[chapter.path] == nil)

        let overviewRel = relations(for: overview, in: entries,
                                    authorIndex: buildAuthorIndex(entries),
                                    annotationIndex: annotationIndex)
        let chapterRel = relations(for: chapter, in: entries,
                                   authorIndex: buildAuthorIndex(entries),
                                   annotationIndex: annotationIndex)
        #expect(overviewRel.annotations.map(\.path) == [note.path])
        #expect(chapterRel.annotations.map(\.path) == [note.path])
    }

    @Test func chapterPathSlugFindsOverviewWhenBookFieldIsMissing() {
        let overview = mk("vault/books/smith-2020/00-overview.md", "book-overview")
        let chapter = mk("vault/books/smith-2020/ch01.md", "chapter-summary")
        let note = mk("vault/notes/chapter-note.md", "note", annotates: chapter.path)
        let entries = [overview, chapter, note]
        let annotationIndex = buildAnnotationIndex(entries)

        #expect(annotationAnchor(for: chapter, in: entries).path == overview.path)
        #expect(annotationIndex[overview.path]?.map(\.path) == [note.path])
    }

    @Test func chapterWithoutOverviewKeepsItsOwnAnnotationAnchor() {
        let chapter = mk("vault/books/missing/ch01.md", "chapter-summary", book: "missing")
        let note = mk("vault/notes/chapter-note.md", "note", annotates: chapter.path)
        let entries = [chapter, note]
        let annotationIndex = buildAnnotationIndex(entries)

        #expect(annotationAnchor(for: chapter, in: entries).path == chapter.path)
        #expect(annotationIndex[chapter.path]?.map(\.path) == [note.path])
    }

    @Test func siblingsAndAuthorProfile() {
        let prof = mk("vault/authors/x.md", "author-profile", title: "Jane Doe")
        let p1 = mk("vault/papers/a.md", "paper-analysis", author: "Jane Doe", rating: 1)
        let p2 = mk("vault/papers/b.md", "paper-analysis", author: "Jane Doe", rating: 3)
        let entries = [prof, p1, p2]
        let rel = relations(for: p1, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.authorProfile?.path == "vault/authors/x.md")
        #expect(rel.siblings.map(\.path) == ["vault/papers/b.md"])  // not self, rating desc
    }

    @Test func similarSharesTwoThemes() {
        let base = mk("vault/papers/a.md", "paper-analysis", themes: ["t1", "t2", "t3"])
        let sim  = mk("vault/papers/b.md", "paper-analysis", themes: ["t1", "t2"], rating: 2)
        let no   = mk("vault/papers/c.md", "paper-analysis", themes: ["t1"])
        let entries = [base, sim, no]
        let rel = relations(for: base, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.similar.map(\.path) == ["vault/papers/b.md"])
    }

    @Test func worksForAuthorProfile() {
        let prof = mk("vault/authors/x.md", "author-profile", title: "Jane Doe")
        let p1 = mk("vault/papers/a.md", "paper-analysis", author: "Jane Doe", rating: 5)
        let entries = [prof, p1]
        let rel = relations(for: prof, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.works.map(\.path) == ["vault/papers/a.md"])
    }
}
