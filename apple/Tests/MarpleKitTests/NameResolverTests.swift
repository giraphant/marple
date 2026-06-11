import Testing
@testable import MarpleKit

@Suite struct NameResolverTests {
    /// Minimal test factory. Omits rarely-needed fields via defaults.
    func mk(path: String, type: EntryType, title: String? = nil,
            journal: String? = nil) -> Entry {
        Entry(path: path, type: type, title: title, author: [],
              year: nil, ratingScore: 0, themes: [],
              preview: "", hasPDF: false,
              journal: journal)
    }

    // — author tier 1 verbatim —
    @Test func authorProfileExactMatchUnchanged() {
        let page = mk(path: "vault/authors/pb.md", type: .author, title: "Pierre Bourdieu")
        #expect(NameResolver.authorProfile(named: " pierre bourdieu ", in: [page])?.path == page.path)
    }
    @Test func authorProfileExactBeatsFolded() {
        let exact  = mk(path: "vault/authors/a.md", type: .author, title: "Pierre Bourdieu")
        let folded = mk(path: "vault/authors/b.md", type: .author, title: "Pierré Bourdieu")
        #expect(NameResolver.authorProfile(named: "Pierre Bourdieu", in: [folded, exact])?.path == exact.path)
    }
    // — approved diff ①: diacritics —
    @Test func authorProfileFoldsDiacritics() {
        let page = mk(path: "vault/authors/pb.md", type: .author, title: "Pierré Bourdieu")
        #expect(NameResolver.authorProfile(named: "Pierre Bourdieu", in: [page])?.path == page.path)
    }
    // — approved diff ②: whitespace collapse —
    @Test func authorProfileCollapsesWhitespace() {
        let page = mk(path: "vault/authors/pb.md", type: .author, title: "Pierre Bourdieu")
        #expect(NameResolver.authorProfile(named: "Pierre  Bourdieu", in: [page])?.path == page.path)
    }
    @Test func authorProfileTypeRestricted() {
        let notAuthor = mk(path: "vault/papers/x.md", type: .paper, title: "Pierre Bourdieu")
        #expect(NameResolver.authorProfile(named: "Pierre Bourdieu", in: [notAuthor]) == nil)
    }
    @Test func authorPagesReturnsAllAtWinningTier() {
        let a = mk(path: "vault/authors/a.md", type: .author, title: "John Smith")
        let b = mk(path: "vault/authors/b.md", type: .author, title: "john smith")
        #expect(NameResolver.authorPages(named: "John Smith", in: [a, b]).map(\.path) == [a.path, b.path])
    }
    // — batch form pins per-call semantics (exact hit / folded fallback / miss / blank / collapse) —
    @Test func authorPageIndexMatchesAuthorPages() {
        let exact = mk(path: "vault/authors/a.md", type: .author, title: "Pierre Bourdieu")
        let folded = mk(path: "vault/authors/b.md", type: .author, title: "Pierré Bourdieu")
        let entries = [exact, folded]
        let idx = NameResolver.AuthorPageIndex(entries)
        for name in ["Pierre Bourdieu", "pierré bourdieu", "Nobody", "  ", "Pierre  Bourdieu"] {
            #expect(idx.pages(named: name).map(\.path)
                 == NameResolver.authorPages(named: name, in: entries).map(\.path),
                 "mismatch for \(name)")
        }
    }
    // — wikilink tier 1 verbatim (title beats stem, no trim) —
    @Test func wikilinkTitleBeatsStem() {
        let byTitle = mk(path: "vault/notes/x.md",      type: .note, title: "Target")
        let byStem  = mk(path: "vault/notes/target.md", type: .note, title: "Other")
        #expect(NameResolver.resolveWikilink("target", in: [byStem, byTitle])?.path == byTitle.path)
    }
    @Test func wikilinkStemFallbackUnchanged() {
        let byStem = mk(path: "vault/notes/target.md", type: .note, title: "Other")
        #expect(NameResolver.resolveWikilink("Target", in: [byStem])?.path == byStem.path)
    }
    // — approved diff ③ —
    @Test func wikilinkFoldsDiacriticsAsLastResort() {
        let page = mk(path: "vault/notes/cafe-note.md", type: .note, title: "Café")
        #expect(NameResolver.resolveWikilink("Cafe", in: [page])?.path == page.path)
    }
    @Test func wikilinkExactStemBeatsFoldedTitle() {
        let foldedTitle = mk(path: "vault/notes/x.md",    type: .note, title: "Café")
        let exactStem   = mk(path: "vault/notes/cafe.md", type: .note, title: "Other")
        #expect(NameResolver.resolveWikilink("cafe", in: [foldedTitle, exactStem])?.path == exactStem.path)
    }
    // — QUA-225 path-form target [[papers/x|label]] resolves by vault-relative path —
    @Test func wikilinkResolvesPathForm() {
        let paper = mk(path: "vault/papers/foo.md", type: .paper, title: "Foo Paper")
        #expect(NameResolver.resolveWikilink("papers/foo", in: [paper])?.path == paper.path)
    }
    @Test func wikilinkPathFormToleratesMdSuffix() {
        let paper = mk(path: "vault/papers/foo.md", type: .paper, title: "Foo Paper")
        #expect(NameResolver.resolveWikilink("papers/foo.md", in: [paper])?.path == paper.path)
    }
    @Test func wikilinkPathFormIsCaseInsensitive() {
        let paper = mk(path: "vault/papers/Foo.md", type: .paper, title: "Foo Paper")
        #expect(NameResolver.resolveWikilink("Papers/foo", in: [paper])?.path == paper.path)
    }
    // Path tier only fires on a `/`-bearing needle; bare stems keep matching by stem.
    @Test func wikilinkBareStemUnaffectedByPathTier() {
        let note = mk(path: "vault/notes/donna-haraway.md", type: .author, title: "Donna Haraway")
        #expect(NameResolver.resolveWikilink("donna-haraway", in: [note])?.path == note.path)
    }
    // — journal verbatim port (new coverage; behavior = old Inspector impl) —
    @Test func journalMatchesByJournalField() {
        let j = mk(path: "vault/journals/jop.md", type: .journal, journal: "Journal of Philosophy")
        #expect(NameResolver.journalEntry(matching: "journal of philosophy", in: [j])?.path == j.path)
    }
    @Test func journalMatchesBySlugForm() {
        let j = mk(path: "vault/journals/jop.md", type: .journal, title: "Journal of Philosophy")
        #expect(NameResolver.journalEntry(matching: "Journal-of-Philosophy", in: [j])?.path == j.path)
    }
    @Test func journalMatchesByPathStem() {
        let j = mk(path: "vault/journals/critical-inquiry.md", type: .journal)
        #expect(NameResolver.journalEntry(matching: "Critical Inquiry", in: [j])?.path == j.path)
    }
    @Test func journalTypeRestricted() {
        let p = mk(path: "vault/papers/x.md", type: .paper, title: "Mind")
        #expect(NameResolver.journalEntry(matching: "Mind", in: [p]) == nil)
    }
    // — blank-input pins —
    @Test func authorPagesBlankNameReturnsEmpty() {
        let page = mk(path: "vault/authors/pb.md", type: .author, title: "Pierre Bourdieu")
        #expect(NameResolver.authorPages(named: "  ", in: [page]).isEmpty)
    }
    @Test func journalEntryBlankValueReturnsNil() {
        let j = mk(path: "vault/journals/jop.md", type: .journal, journal: "Journal of Philosophy")
        #expect(NameResolver.journalEntry(matching: "", in: [j]) == nil)
    }
    // Pins a legacy WikiResolver quirk carried verbatim into tier 1: an empty
    // target matches any nil-title entry because ($0.title ?? "") == "".
    // The folded tier guards against empty needles, but tier 1 deliberately
    // doesn't — "fixing" this asymmetry would be an unapproved behavior change.
    @Test func wikilinkEmptyTargetMatchesNilTitleEntry() {
        let nilTitle = mk(path: "vault/notes/x.md", type: .note)
        #expect(NameResolver.resolveWikilink("", in: [nilTitle])?.path == nilTitle.path)
    }
    // — folded tier returns ALL folded-equal pages, document order —
    @Test func authorPagesAllMatchesAtFoldedTier() {
        let a = mk(path: "vault/authors/a.md", type: .author, title: "Pierré Bourdieu")
        let b = mk(path: "vault/authors/b.md", type: .author, title: "PIERRÉ  Bourdieu")
        #expect(NameResolver.authorPages(named: "Pierre Bourdieu", in: [a, b]).map(\.path) == [a.path, b.path])
    }
}
