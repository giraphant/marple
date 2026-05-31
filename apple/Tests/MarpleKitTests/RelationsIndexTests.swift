import Testing
@testable import MarpleKit

@Suite struct RelationsIndexTests {
    /// Test factory — accepts a legacy joined-string `author` for terseness;
    /// `splitAuthors` converts it to the canonical `[String]` on construction.
    func mk(_ path: String, _ type: String, title: String? = nil, author: String? = nil,
            themes: [String] = [], topics: [String] = [], rating: Double = 0, book: String? = nil,
            annotates: String? = nil) -> Entry {
        Entry(path: path, type: EntryType(rawValue: type), title: title,
              author: splitAuthors(author),
              year: nil, ratingScore: rating, themes: themes, topics: topics,
              preview: "", hasPDF: false,
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
        let p = mk("vault/papers/p.md", "paper")
        let n = mk("vault/notes/n.md", "note", annotates: "vault/papers/p.md")
        let entries = [p, n]
        let rel = relations(for: p, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.annotations.map(\.path) == ["vault/notes/n.md"])
    }

    @Test func chapterAnnotationsResolveToBookOverview() {
        let overview = mk("vault/books/smith-2020/00-overview.md", "book")
        let chapter = mk("vault/books/smith-2020/ch01.md", "chapter", book: "smith-2020")
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
        let overview = mk("vault/books/smith-2020/00-overview.md", "book")
        let chapter = mk("vault/books/smith-2020/ch01.md", "chapter")
        let note = mk("vault/notes/chapter-note.md", "note", annotates: chapter.path)
        let entries = [overview, chapter, note]
        let annotationIndex = buildAnnotationIndex(entries)

        #expect(annotationAnchor(for: chapter, in: entries).path == overview.path)
        #expect(annotationIndex[overview.path]?.map(\.path) == [note.path])
    }

    @Test func chapterWithoutOverviewKeepsItsOwnAnnotationAnchor() {
        let chapter = mk("vault/books/missing/ch01.md", "chapter", book: "missing")
        let note = mk("vault/notes/chapter-note.md", "note", annotates: chapter.path)
        let entries = [chapter, note]
        let annotationIndex = buildAnnotationIndex(entries)

        #expect(annotationAnchor(for: chapter, in: entries).path == chapter.path)
        #expect(annotationIndex[chapter.path]?.map(\.path) == [note.path])
    }

    @Test func siblingsAndAuthorProfile() {
        let prof = mk("vault/authors/x.md", "author", title: "Jane Doe")
        let p1 = mk("vault/papers/a.md", "paper", author: "Jane Doe", rating: 1)
        let p2 = mk("vault/papers/b.md", "paper", author: "Jane Doe", rating: 3)
        let entries = [prof, p1, p2]
        let rel = relations(for: p1, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.authorProfile?.path == "vault/authors/x.md")
        #expect(rel.siblings.map(\.path) == ["vault/papers/b.md"])  // not self, rating desc
    }

    @Test func similarSharesTwoThemes() {
        let base = mk("vault/papers/a.md", "paper", themes: ["t1", "t2", "t3"])
        let sim  = mk("vault/papers/b.md", "paper", themes: ["t1", "t2"], rating: 2)
        let no   = mk("vault/papers/c.md", "paper", themes: ["t1"])
        let entries = [base, sim, no]
        let rel = relations(for: base, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.similar.map(\.path) == ["vault/papers/b.md"])
    }

    @Test func chapterBorrowsOverviewAuthorRelations() {
        let overview = mk("vault/books/smith-2020/00-overview.md", "book", author: "Jane Doe")
        let chapter = mk("vault/books/smith-2020/ch01.md", "chapter", book: "smith-2020")
        let sameAuthorPaper = mk("vault/papers/p.md", "paper", author: "Jane Doe", rating: 3)
        let sameAuthorBook = mk("vault/books/other/00-overview.md", "book", author: "Jane Doe", rating: 2)
        let sameAuthorChapter = mk("vault/books/other/ch01.md", "chapter", author: "Jane Doe", rating: 4, book: "other")
        let entries = [overview, chapter, sameAuthorPaper, sameAuthorBook, sameAuthorChapter]

        let rel = relations(for: chapter, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))

        #expect(rel.siblings.map(\.path) == ["vault/papers/p.md", "vault/books/other/00-overview.md"])
    }

    @Test func topicPageShowsEntriesDeclaringTopicMembership() {
        let topic = mk("vault/topics/repair/00-overview.md", "topic", title: "Repair")
        let paper = mk("vault/papers/p.md", "paper", topics: ["repair"], rating: 2)
        let book = mk("vault/books/b/00-overview.md", "book", topics: ["repair"], rating: 3)
        let chapter = mk("vault/books/b/ch01.md", "chapter", topics: ["repair"], rating: 4, book: "b")
        let other = mk("vault/papers/other.md", "paper", topics: ["hci"], rating: 5)
        let entries = [topic, paper, book, chapter, other]
        let topicMembership = buildTopicMembership(entries)

        let rel = relations(for: topic, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries),
                            topicMembership: topicMembership)

        #expect(rel.topicMembers.map(\.path) == ["vault/books/b/00-overview.md", "vault/papers/p.md"])
    }

    @Test func worksForAuthorProfile() {
        let prof = mk("vault/authors/x.md", "author", title: "Jane Doe")
        let p1 = mk("vault/papers/a.md", "paper", author: "Jane Doe", rating: 5)
        let entries = [prof, p1]
        let rel = relations(for: prof, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.works.map(\.path) == ["vault/papers/a.md"])
    }
}
