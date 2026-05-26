import Testing
@testable import MarpleKit

@Suite struct ListSortTests {
    func e(_ path: String, title: String? = nil, year: String? = nil,
           rating: Double = 0, mtime: Double? = nil, added: Double? = nil) -> Entry {
        Entry(path: path, type: .paperAnalysis, title: title, author: [], year: year,
              ratingScore: rating, themes: [], preview: "", hasPDF: false,
              mtime: mtime, added: added)
    }

    @Test func testEmptyClausesPreserveOrder() {
        let list = [e("a"), e("b"), e("c")]
        #expect(sortEntries(list, by: []).map(\.path) == ["a", "b", "c"])
    }

    @Test func testRatingDescEmptiesLast() {
        let list = [e("a", rating: 0), e("b", rating: 4), e("c", rating: 2)]
        let out = sortEntries(list, by: [SortClause(field: .rating, dir: .desc)])
        #expect(out.map(\.path) == ["b", "c", "a"])
    }

    @Test func testRatingAscStillFloatsEmptiesLast() {
        let list = [e("a", rating: 0), e("b", rating: 4), e("c", rating: 2)]
        let out = sortEntries(list, by: [SortClause(field: .rating, dir: .asc)])
        #expect(out.map(\.path) == ["c", "b", "a"])
    }

    @Test func testMultiClauseTieBreak() {
        // same year, break by rating desc
        let list = [e("a", year: "2020", rating: 1),
                    e("b", year: "2020", rating: 3),
                    e("c", year: "2019", rating: 5)]
        let out = sortEntries(list, by: [SortClause(field: .year, dir: .desc),
                                         SortClause(field: .rating, dir: .desc)])
        #expect(out.map(\.path) == ["b", "a", "c"])
    }

    @Test func testTitleLocaleAsc() {
        let list = [e("a", title: "Beta"), e("b", title: "alpha"), e("c", title: nil)]
        let out = sortEntries(list, by: [SortClause(field: .title, dir: .asc)])
        #expect(out.map(\.path) == ["b", "a", "c"])  // nil title last
    }
}
