import Testing
@testable import MarpleKit

@Suite struct RelationGraphTests {
    /// Test factory — same shape as RelationsIndexTests.mk: joined-string
    /// `author` split via `splitAuthors` on construction.
    func mk(_ path: String, _ type: String, title: String? = nil, author: String? = nil,
            book: String? = nil, annotates: String? = nil) -> Entry {
        Entry(path: path, type: EntryType(rawValue: type), title: title,
              author: splitAuthors(author),
              year: nil, ratingScore: 0, themes: [], topics: [],
              preview: "", hasPDF: false,
              book: book, annotates: annotates)
    }

    @Test func authoredByForwardAndReverse() {
        let page = mk("vault/authors/smith.md", "author", title: "Smith")
        let paper = mk("vault/papers/p.md", "paper", author: "Smith")
        let g = RelationGraph.build([page, paper])
        #expect(g.targets(of: paper.path, kind: .authoredBy).map(\.path) == [page.path])
        #expect(g.sources(of: page.path, kind: .authoredBy).map(\.path) == [paper.path])
    }

    @Test func duplicateAuthorPagesBothGetWorks() {
        // legacy: works looked up by page-title key — two same-named pages saw the same list
        let a = mk("vault/authors/a.md", "author", title: "Smith")
        let b = mk("vault/authors/b.md", "author", title: "smith")
        let paper = mk("vault/papers/p.md", "paper", author: "Smith")
        let g = RelationGraph.build([a, b, paper])
        #expect(g.sources(of: a.path, kind: .authoredBy).map(\.path) == [paper.path])
        #expect(g.sources(of: b.path, kind: .authoredBy).map(\.path) == [paper.path])
        #expect(g.targets(of: paper.path, kind: .authoredBy).first?.path == a.path) // entries.first semantics
        #expect(g.worksByAuthorKey["smith"]?.map(\.path) == [paper.path])
    }

    @Test func multiAuthorEdgeOrderFollowsAuthorArray() {
        // Edge.position is not consumable from outside yet (the edges list is
        // private until PR3); its observable consequence is that targets()
        // order follows the author-array order, not document order.
        let pageA = mk("vault/authors/a.md", "author", title: "Alice A")
        let pageB = mk("vault/authors/b.md", "author", title: "Bob B")
        let paper = mk("vault/papers/p.md", "paper", author: "Alice A, Bob B")
        let g = RelationGraph.build([pageB, pageA, paper]) // doc order reversed vs author order
        #expect(g.targets(of: paper.path, kind: .authoredBy).map(\.path) == [pageA.path, pageB.path])
    }

    @Test func foldedPageSuppressedWhenExactPageExists() {
        let exact = mk("vault/authors/exact.md", "author", title: "Pierre Bourdieu")
        let folded = mk("vault/authors/folded.md", "author", title: "Pierré Bourdieu")
        let paper = mk("vault/papers/p.md", "paper", author: "Pierre Bourdieu")
        let g = RelationGraph.build([exact, folded, paper])
        #expect(g.targets(of: paper.path, kind: .authoredBy).map(\.path) == [exact.path])
        #expect(g.sources(of: folded.path, kind: .authoredBy).isEmpty)
    }

    @Test func multipleNotesOnSameTargetKeepDocumentOrder() {
        let p = mk("vault/papers/p.md", "paper")
        let n1 = mk("vault/notes/n1.md", "note", annotates: p.path)
        let n2 = mk("vault/notes/n2.md", "note", annotates: p.path)
        let g = RelationGraph.build([p, n1, n2])
        #expect(g.sources(of: p.path, kind: .annotates).map(\.path) == [n1.path, n2.path])
    }

    @Test func foldedTierOnlyWhenNoExactPage() {
        let folded = mk("vault/authors/pb.md", "author", title: "Pierré Bourdieu")
        let paper = mk("vault/papers/p.md", "paper", author: "Pierre Bourdieu")
        let g = RelationGraph.build([folded, paper])
        #expect(g.sources(of: folded.path, kind: .authoredBy).map(\.path) == [paper.path])
    }

    @Test func authoredByOnlyFromPapersAndBooks() {
        let page = mk("vault/authors/smith.md", "author", title: "Smith")
        let note = mk("vault/notes/n.md", "note", author: "Smith")
        let g = RelationGraph.build([page, note])
        #expect(g.sources(of: page.path, kind: .authoredBy).isEmpty)
    }

    @Test func worksByAuthorKeyMatchesLegacyAuthorIndex() {
        let p1 = mk("vault/papers/a.md", "paper", author: "Jane Doe")
        let p2 = mk("vault/papers/b.md", "paper", author: "jane doe")
        let g = RelationGraph.build([p1, p2])
        #expect(g.worksByAuthorKey["jane doe"]?.map(\.path) == [p1.path, p2.path])
        #expect(g.worksByAuthorKey == buildAuthorIndex([p1, p2]))
    }

    @Test func annotatesEdgeWithChapterAnchorRemap() {
        let overview = mk("vault/books/b/00-overview.md", "book")
        let chapter = mk("vault/books/b/01-c.md", "chapter", book: "b")
        let note = mk("vault/notes/n.md", "note", annotates: chapter.path)
        let g = RelationGraph.build([overview, chapter, note])
        #expect(g.sources(of: overview.path, kind: .annotates).map(\.path) == [note.path])
        #expect(g.targets(of: note.path, kind: .annotates).map(\.path) == [overview.path])
    }

    @Test func annotatesDanglingTargetKeepsRawPath() {
        let note = mk("vault/notes/n.md", "note", annotates: "vault/papers/gone.md")
        let g = RelationGraph.build([note])
        #expect(g.sources(of: "vault/papers/gone.md", kind: .annotates).map(\.path) == [note.path])
    }

    @Test func emptyAndIsEmpty() {
        #expect(RelationGraph.empty.isEmpty)
        let page = mk("vault/authors/x.md", "author", title: "X")
        let paper = mk("vault/papers/p.md", "paper", author: "X")
        #expect(!RelationGraph.build([page, paper]).isEmpty)
    }
}
