import Testing
import Foundation
@testable import MarpleKit

@Suite("SourceResolver")
struct SourceResolverTests {

    // MARK: - bookSlug

    @Test("bookSlug: extracts first component after vault/books/")
    func bookSlugBasic() {
        #expect(bookSlug("vault/books/smith-dog-2020/ch3.md") == "smith-dog-2020")
    }

    @Test("bookSlug: nested path — still first component")
    func bookSlugNested() {
        #expect(bookSlug("vault/books/some-book-1999/sub/ch1.md") == "some-book-1999")
    }

    @Test("bookSlug: wrong prefix → nil")
    func bookSlugWrongPrefix() {
        #expect(bookSlug("vault/papers/foo.md") == nil)
    }

    @Test("bookSlug: empty slug after prefix → nil")
    func bookSlugEmptySlug() {
        // "vault/books/" with nothing after — no first component
        #expect(bookSlug("vault/books/") == nil)
    }

    // MARK: - pdfSlug

    @Test("pdfSlug: paper-analysis → fileStem")
    func pdfSlugPaperAnalysis() {
        #expect(pdfSlug(type: "paper-analysis", rel: "vault/papers/foo.md", fileStem: "foo") == "foo")
    }

    @Test("pdfSlug: book-overview → bookSlug(rel)")
    func pdfSlugBookOverview() {
        #expect(pdfSlug(type: "book-overview", rel: "vault/books/smith-dog-2020/overview.md", fileStem: "overview") == "smith-dog-2020")
    }

    @Test("pdfSlug: book-overview with no vault/books prefix → nil")
    func pdfSlugBookOverviewNilSlug() {
        #expect(pdfSlug(type: "book-overview", rel: "vault/papers/overview.md", fileStem: "overview") == nil)
    }

    @Test("pdfSlug: chapter-summary → bookSlug-fileStem")
    func pdfSlugChapterSummary() {
        #expect(pdfSlug(type: "chapter-summary", rel: "vault/books/x/ch1.md", fileStem: "ch1") == "x-ch1")
    }

    @Test("pdfSlug: other type → nil")
    func pdfSlugOtherType() {
        #expect(pdfSlug(type: "note", rel: "vault/notes/foo.md", fileStem: "foo") == nil)
        #expect(pdfSlug(type: "topic-synthesis", rel: "vault/topics/x.md", fileStem: "x") == nil)
    }

    // MARK: - loadSourceSlugs

    @Test("loadSourceSlugs: collects PDF stems case-insensitively, ignores non-PDF")
    func loadSourceSlugsBasic() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-resolver-test-\(Int.random(in: 1_000_000...9_999_999))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create test files
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("a.pdf").path, contents: nil)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("B.PDF").path, contents: nil)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("c.txt").path, contents: nil)

        let slugs = loadSourceSlugs(sourcesDir: tmp.path)
        // Should contain "a" and "B" (exact stems), not "c"
        #expect(slugs.contains("a"))
        #expect(slugs.contains("B"))
        #expect(!slugs.contains("c"))
        #expect(slugs.count == 2)
    }

    @Test("loadSourceSlugs: non-existent dir → empty set")
    func loadSourceSlugsNonExistent() {
        let slugs = loadSourceSlugs(sourcesDir: "/nonexistent/path/that/does/not/exist")
        #expect(slugs.isEmpty)
    }

    // MARK: - hasPDF

    @Test("hasPDF: exact match → true")
    func hasPDFExactMatch() {
        let slugs: Set<String> = ["bennett-birth-of-the-museum-1995", "smith-other-book-2010"]
        #expect(hasPDF(slug: "bennett-birth-of-the-museum-1995", sourceSlugs: slugs))
    }

    @Test("hasPDF: no match at all → false")
    func hasPDFNoMatch() {
        let slugs: Set<String> = ["jones-something-else-2010"]
        #expect(!hasPDF(slug: "smith-completely-unrelated-2020", sourceSlugs: slugs))
    }

    @Test("hasPDF: fuzzy match (reworded title same author) → true")
    func hasPDFFuzzyMatch() {
        // From Rust test: matches_reworded_title_same_author_unique
        let slugs: Set<String> = ["bennett-birth-of-the-museum-1995", "foucault-discipline-and-punish-1977"]
        // The vault slug has extra "the" articles; should still match via fuzzy
        #expect(hasPDF(slug: "bennett-the-birth-of-the-museum-1995", sourceSlugs: slugs))
    }

    @Test("hasPDF: empty slug → false")
    func hasPDFEmptySlug() {
        let slugs: Set<String> = ["bennett-birth-of-the-museum-1995"]
        #expect(!hasPDF(slug: "", sourceSlugs: slugs))
    }

    // MARK: - fuzzyPickSource (verbatim Rust test parity)

    // Rust test: matches_reworded_title_same_author_unique
    @Test("fuzzyPickSource: matches reworded title same author unique")
    func fuzzyMatchesRewordedTitleSameAuthorUnique() {
        let cands: Set<String> = [
            "bennett-birth-of-the-museum-1995",
            "foucault-discipline-and-punish-1977",
        ]
        #expect(
            fuzzyPickSource("bennett-the-birth-of-the-museum-1995", cands)
            == "bennett-birth-of-the-museum-1995"
        )
    }

    // Rust test: rejects_same_author_different_title
    @Test("fuzzyPickSource: rejects same author different title")
    func fuzzyRejectsSameAuthorDifferentTitle() {
        let cands: Set<String> = ["smith-the-quantified-mind-2015"]
        #expect(fuzzyPickSource("smith-the-digital-body-2020", cands) == nil)
    }

    // Rust test: rejects_ambiguous_ties
    @Test("fuzzyPickSource: rejects ambiguous ties (two editions, same title)")
    func fuzzyRejectsAmbiguousTies() {
        let cands: Set<String> = [
            "lupton-quantified-self-tracking-2016",
            "lupton-quantified-self-tracking-2018",
        ]
        #expect(fuzzyPickSource("lupton-quantified-self-tracking-2020", cands) == nil)
    }

    // Rust test: rejects_too_little_title_signal
    @Test("fuzzyPickSource: rejects too little title signal (only 1 significant token)")
    func fuzzyRejectsTooLittleTitleSignal() {
        let cands: Set<String> = ["smith-the-body-and-society-2020"]
        #expect(fuzzyPickSource("smith-body-2020", cands) == nil)
    }

    // Rust test: requires_same_lastname
    @Test("fuzzyPickSource: requires same lastname")
    func fuzzyRequiresSameLastname() {
        let cands: Set<String> = ["jones-quantified-self-tracking-2016"]
        #expect(fuzzyPickSource("lupton-quantified-self-tracking-2016", cands) == nil)
    }

    // Rust test: rejects_subset_title_with_distant_year
    @Test("fuzzyPickSource: rejects subset title with distant year")
    func fuzzyRejectsSubsetTitleWithDistantYear() {
        let cands: Set<String> = ["kern-culture-of-time-and-space-1983"]
        #expect(fuzzyPickSource("kern-time-and-space-in-1920", cands) == nil)
    }

    // Rust test: matches_truncated_title_with_close_year
    @Test("fuzzyPickSource: matches truncated title with close year")
    func fuzzyMatchesTruncatedTitleWithCloseYear() {
        let cands: Set<String> = ["ahmed-queer-phenomenology-2006"]
        #expect(
            fuzzyPickSource("ahmed-orientations-queer-phenomenology-2006", cands)
            == "ahmed-queer-phenomenology-2006"
        )
    }

    // Rust test: matches_identical_title_despite_distant_year
    @Test("fuzzyPickSource: matches identical title despite distant year (typo 1883→1983)")
    func fuzzyMatchesIdenticalTitleDespiteDistantYear() {
        let cands: Set<String> = ["kern-culture-of-time-and-space-1983"]
        #expect(
            fuzzyPickSource("kern-culture-of-time-and-space-1883", cands)
            == "kern-culture-of-time-and-space-1983"
        )
    }

    // Additional edge cases
    @Test("fuzzyPickSource: empty slug → nil")
    func fuzzyEmptySlug() {
        let cands: Set<String> = ["some-valid-slug-2020"]
        #expect(fuzzyPickSource("", cands) == nil)
    }

    @Test("fuzzyPickSource: empty candidates → nil")
    func fuzzyEmptyCandidates() {
        #expect(fuzzyPickSource("smith-some-book-2020", []) == nil)
    }
}
