import Testing
@testable import MarpleKit

@Suite struct RelationsIndexTests {
    /// Test factory — accepts a legacy joined-string `author` for terseness;
    /// `splitAuthors` converts it to the canonical `[String]` on construction.
    func mk(_ path: String, _ type: String, title: String? = nil, author: String? = nil,
            themes: [String] = [], topics: [String] = [], rating: Double = 0, book: String? = nil,
            annotates: String? = nil, journal: String? = nil) -> Entry {
        Entry(path: path, type: EntryType(rawValue: type), title: title,
              author: splitAuthors(author),
              year: nil, ratingScore: rating, themes: themes, topics: topics,
              preview: "", hasPDF: false,
              book: book, journal: journal, annotates: annotates)
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
        let rel = relations(for: p, in: entries, graph: RelationGraph.build(entries))
        #expect(rel.annotations.map(\.path) == ["vault/notes/n.md"])
    }

    @Test func chapterAnnotationTargetsBookOverview() {
        let overview = mk("vault/books/smith-2020/00-overview.md", "book")
        let chapter = mk("vault/books/smith-2020/ch01.md", "chapter", book: "smith-2020")

        #expect(annotationTarget(for: chapter, in: [overview, chapter]).path == overview.path)
    }

    // A book and every chapter share one annotation surface. Existing notes whose
    // frontmatter still points at a chapter remain part of that book-level set.
    @Test func bookAndChaptersShareAnnotations() {
        let overview = mk("vault/books/smith-2020/00-overview.md", "book")
        let ch1 = mk("vault/books/smith-2020/ch01.md", "chapter", book: "smith-2020")
        let ch2 = mk("vault/books/smith-2020/ch02.md", "chapter", book: "smith-2020")
        let bookNote = mk("vault/notes/book-note.md", "note", annotates: overview.path)
        let chNote = mk("vault/notes/chapter-note.md", "note", annotates: ch1.path)
        let entries = [overview, ch1, ch2, bookNote, chNote]
        let graph = RelationGraph.build(entries)

        // 边忠实：章节笔记指向章节本身，未上卷到 overview
        #expect(graph.sources(of: ch1.path, kind: .annotates).map(\.path) == [chNote.path])
        #expect(graph.sources(of: overview.path, kind: .annotates).map(\.path) == [bookNote.path])

        let expected = Set([bookNote.path, chNote.path])
        #expect(Set(relations(for: overview, in: entries, graph: graph).annotations.map(\.path)) == expected)
        #expect(Set(relations(for: ch1, in: entries, graph: graph).annotations.map(\.path)) == expected)
        #expect(Set(relations(for: ch2, in: entries, graph: graph).annotations.map(\.path)) == expected)
    }

    // overview 聚合靠 bookContext 的 path-slug 匹配，章节缺 `book` 字段也成立。
    @Test func overviewAggregatesChapterWhenBookFieldIsMissing() {
        let overview = mk("vault/books/smith-2020/00-overview.md", "book")
        let chapter = mk("vault/books/smith-2020/ch01.md", "chapter")
        let note = mk("vault/notes/chapter-note.md", "note", annotates: chapter.path)
        let entries = [overview, chapter, note]
        let graph = RelationGraph.build(entries)

        #expect(graph.sources(of: chapter.path, kind: .annotates).map(\.path) == [note.path])
        #expect(relations(for: overview, in: entries, graph: graph).annotations.map(\.path) == [note.path])
    }

    // 无 overview 的孤儿章节：笔记忠实挂在章节自己名下。
    @Test func chapterWithoutOverviewKeepsItsOwnAnnotations() {
        let chapter = mk("vault/books/missing/ch01.md", "chapter", book: "missing")
        let note = mk("vault/notes/chapter-note.md", "note", annotates: chapter.path)
        let entries = [chapter, note]
        let graph = RelationGraph.build(entries)

        #expect(graph.sources(of: chapter.path, kind: .annotates).map(\.path) == [note.path])
        #expect(relations(for: chapter, in: entries, graph: graph).annotations.map(\.path) == [note.path])
    }

    @Test func siblingsAndAuthorProfile() {
        let prof = mk("vault/authors/x.md", "author", title: "Jane Doe")
        let p1 = mk("vault/papers/a.md", "paper", author: "Jane Doe", rating: 1)
        let p2 = mk("vault/papers/b.md", "paper", author: "Jane Doe", rating: 3)
        let entries = [prof, p1, p2]
        let rel = relations(for: p1, in: entries, graph: RelationGraph.build(entries))
        #expect(rel.authorProfile?.path == "vault/authors/x.md")
        #expect(rel.siblings.map(\.path) == ["vault/papers/b.md"])  // not self, rating desc
    }

    @Test func similarSharesTwoThemes() {
        let base = mk("vault/papers/a.md", "paper", themes: ["t1", "t2", "t3"])
        let sim  = mk("vault/papers/b.md", "paper", themes: ["t1", "t2"], rating: 2)
        let no   = mk("vault/papers/c.md", "paper", themes: ["t1"])
        let entries = [base, sim, no]
        let rel = relations(for: base, in: entries, graph: RelationGraph.build(entries))
        #expect(rel.similar.map(\.path) == ["vault/papers/b.md"])
    }

    @Test func chapterBorrowsOverviewAuthorRelations() {
        let overview = mk("vault/books/smith-2020/00-overview.md", "book", author: "Jane Doe")
        let chapter = mk("vault/books/smith-2020/ch01.md", "chapter", book: "smith-2020")
        let sameAuthorPaper = mk("vault/papers/p.md", "paper", author: "Jane Doe", rating: 3)
        let sameAuthorBook = mk("vault/books/other/00-overview.md", "book", author: "Jane Doe", rating: 2)
        let sameAuthorChapter = mk("vault/books/other/ch01.md", "chapter", author: "Jane Doe", rating: 4, book: "other")
        let entries = [overview, chapter, sameAuthorPaper, sameAuthorBook, sameAuthorChapter]

        let rel = relations(for: chapter, in: entries, graph: RelationGraph.build(entries))

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
                            graph: RelationGraph.build(entries),
                            topicMembership: topicMembership)

        #expect(rel.topicMembers.map(\.path) == ["vault/books/b/00-overview.md", "vault/papers/p.md"])
    }

    @Test func worksForAuthorProfile() {
        let prof = mk("vault/authors/x.md", "author", title: "Jane Doe")
        let p1 = mk("vault/papers/a.md", "paper", author: "Jane Doe", rating: 5)
        let entries = [prof, p1]
        let rel = relations(for: prof, in: entries, graph: RelationGraph.build(entries))
        #expect(rel.works.map(\.path) == ["vault/papers/a.md"])
    }

    // QUA-218 规则①收口：作者页"作品"补全 talk（讲者经 speaker 别名折进 author）。
    @Test func worksIncludeTalksAndImages() {
        let prof = mk("vault/authors/x.md", "author", title: "Jane Doe")
        let paper = mk("vault/papers/a.md", "paper", author: "Jane Doe", rating: 5)
        let talk = mk("vault/talks/t/talk.md", "talk", author: "Jane Doe", rating: 3)
        let entries = [prof, paper, talk]
        let rel = relations(for: prof, in: entries, graph: RelationGraph.build(entries))
        #expect(Set(rel.works.map(\.path)) == ["vault/papers/a.md", "vault/talks/t/talk.md"])
    }

    // QUA-218 规则①：journal 页反向列出本刊论文（inJournal 边）。
    @Test func journalPageListsItsArticles() {
        let jrnl = mk("vault/journals/soc/00-overview.md", "journal", title: "Sociology")
        let p1 = mk("vault/papers/a.md", "paper", rating: 2, journal: "Sociology")
        let p2 = mk("vault/papers/b.md", "paper", rating: 5, journal: "Sociology")
        let other = mk("vault/papers/c.md", "paper", journal: "Nature")
        let entries = [jrnl, p1, p2, other]
        let rel = relations(for: jrnl, in: entries, graph: RelationGraph.build(entries))
        // rating desc
        #expect(rel.journalArticles.map(\.path) == ["vault/papers/b.md", "vault/papers/a.md"])
    }

    // topic 子页（resources）也展示该 slug 的成员：归一到 overview anchor。
    @Test func topicSubPageShowsSlugMembers() {
        let overview = mk("vault/topics/repair/00-overview.md", "topic", title: "Repair")
        let resources = mk("vault/topics/repair/01-resources.md", "topic", title: "Repair 资源")
        let paper = mk("vault/papers/p.md", "paper", topics: ["repair"], rating: 2)
        let entries = [overview, resources, paper]
        let membership = buildTopicMembership(entries)
        let rel = relations(for: resources, in: entries,
                            graph: RelationGraph.build(entries), topicMembership: membership)
        #expect(rel.topicMembers.map(\.path) == ["vault/papers/p.md"])
    }
}
