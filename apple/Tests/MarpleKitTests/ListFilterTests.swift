import Foundation
import Testing
@testable import MarpleKit

@Suite struct ListFilterTests {
    func e(_ path: String, author: String? = nil, year: String? = nil, rating: Double = 0,
           themes: [String] = [], source: String? = nil, hasPDF: Bool = false,
           added: Double? = nil) -> Entry {
        Entry(path: path, type: .paperAnalysis, title: nil, author: author, year: year,
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

    @Test func testAddedWithinDays() {
        let now = Date(timeIntervalSince1970: 1_000_000) // fixed
        let recent = (now.timeIntervalSince1970 - 86400) * 1000   // 1 day ago, ms
        let old = (now.timeIntervalSince1970 - 10 * 86400) * 1000 // 10 days ago
        let list = [e("a", added: recent), e("b", added: old)]
        let cs = [FilterClause(field: .added, op: .within, value: "3")]
        #expect(applyFilters(list, cs, match: .all, now: now).map(\.path) == ["a"])
    }
}
