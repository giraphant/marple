import Foundation
import Testing
@testable import MarpleKit

@Suite struct ListFilterTests {
    /// Test factory — accepts a legacy joined-string `author` for terseness;
    /// `splitAuthors` converts it to the canonical `[String]` on construction.
    func e(_ path: String, author: String? = nil, year: String? = nil, rating: Double = 0,
           themes: [String] = [], source: String? = nil, hasPDF: Bool = false,
           added: Double? = nil) -> Entry {
        Entry(path: path, type: .paper, title: nil,
              author: splitAuthors(author), year: year,
              ratingScore: rating, themes: themes, preview: "", hasPDF: hasPDF,
              mtime: nil, added: added, source: source)
    }

    @Test func testNoClausesReturnsAll() {
        let list = [e("a"), e("b")]
        #expect(applyFilters(list, [], match: .all).count == 2)
    }

    @Test func testRatingGteAndHasPdfAll() {
        let list = [e("a", rating: 4, hasPDF: true), e("b", rating: 4, hasPDF: false),
                    e("c", rating: 1, hasPDF: true)]
        let cs = [FilterClause(field: .rating, op: .gte, value: "3"),
                  FilterClause(field: .haspdf, op: .yes, value: "")]
        #expect(applyFilters(list, cs, match: .all).map(\.path) == ["a"])
    }

    @Test func testAnyMode() {
        let list = [e("a", rating: 4), e("b", year: "2020"), e("c")]
        let cs = [FilterClause(field: .rating, op: .gte, value: "3"),
                  FilterClause(field: .year, op: .gte, value: "2000")]
        #expect(Set(applyFilters(list, cs, match: .any).map(\.path)) == ["a", "b"])
    }

    @Test func testIncompleteClauseIgnored() {
        let list = [e("a", rating: 1)]
        let cs = [FilterClause(field: .rating, op: .gte, value: "")]  // no value
        #expect(applyFilters(list, cs, match: .all).count == 1)
    }

    @Test func testThemeIsVsContains() {
        let list = [e("a", themes: ["macro econ"]), e("b", themes: ["econ"])]
        #expect(applyFilters(list, [FilterClause(field: .theme, op: .is_, value: "econ")],
                             match: .all).map(\.path) == ["b"])
        #expect(Set(applyFilters(list, [FilterClause(field: .theme, op: .contains, value: "econ")],
                                 match: .all).map(\.path)) == ["a", "b"])
    }

    /// QUA-109 contract: author filter is "any author contains needle"
    /// (case-insensitive substring against each author independently). This
    /// replaces the pre-QUA-109 behavior of substring-matching against the
    /// joined string, which let queries like ", " match any multi-author
    /// entry. Document the new contract here so future refactors don't
    /// regress it silently.
    @Test func testAuthorFilterMatchesAnyAuthor() {
        let solo = Entry(path: "vault/papers/solo.md", type: .paper,
                         title: nil, author: ["Sara Ahmed"], year: nil,
                         ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let pair = Entry(path: "vault/papers/pair.md", type: .paper,
                         title: nil, author: ["Sara Ahmed", "Jane Doe"], year: nil,
                         ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let other = Entry(path: "vault/papers/other.md", type: .paper,
                          title: nil, author: ["John Smith"], year: nil,
                          ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let list = [solo, pair, other]

        // Single-name needle matches both entries that have that author.
        let aClause = FilterClause(field: .author, op: .contains, value: "Sara")
        let hits = applyFilters(list, [aClause], match: .all).map(\.path)
        #expect(Set(hits) == ["vault/papers/solo.md", "vault/papers/pair.md"])

        // The ", " needle no longer falsely matches multi-author entries by
        // exploiting the joined-string separator.
        let bClause = FilterClause(field: .author, op: .contains, value: ", ")
        #expect(applyFilters(list, [bClause], match: .all).isEmpty)
    }

    /// QUA-127: type is a filter axis (value = EntryType rawValue, op = is).
    @Test func testTypeFilter() {
        let paper = e("p")  // factory builds .paper
        let book = Entry(path: "b", type: .book, title: nil, author: [], year: nil,
                         ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let list = [paper, book]
        let cs = [FilterClause(field: .type, op: .is_, value: "paper")]
        #expect(applyFilters(list, cs, match: .all).map(\.path) == ["p"])
        // Composes with other clauses — the issue's headline example shape.
        let combo = [FilterClause(field: .type, op: .is_, value: "book"),
                     FilterClause(field: .rating, op: .gte, value: "1")]
        #expect(applyFilters(list, combo, match: .all).isEmpty)
        // Empty value = incomplete clause, ignored.
        #expect(applyFilters(list, [FilterClause(field: .type, op: .is_, value: "")],
                             match: .all).count == 2)
    }

    @Test func testTypeClauseLabelUsesHumanLabel() {
        #expect(clauseLabel(FilterClause(field: .type, op: .is_, value: "paper")) == "类型 是 论文")
    }

    @Test func testAddedWithinDays() {
        let now = Date(timeIntervalSince1970: 1_000_000) // fixed
        let recent = (now.timeIntervalSince1970 - 86400) * 1000   // 1 day ago, ms
        let old = (now.timeIntervalSince1970 - 10 * 86400) * 1000 // 10 days ago
        let list = [e("a", added: recent), e("b", added: old)]
        let cs = [FilterClause(field: .added, op: .within, value: "3")]
        #expect(applyFilters(list, cs, match: .all, now: now).map(\.path) == ["a"])
    }
}
