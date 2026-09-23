import Testing
@testable import MarpleKit

@Suite struct ListSortTests {
    func e(_ path: String, title: String? = nil, year: String? = nil,
           rating: Double = 0, mtime: Double? = nil, added: Double? = nil) -> Entry {
        Entry(path: path, type: .paper, title: title, author: [], year: year,
              ratingScore: rating, themes: [], preview: "", hasPDF: false,
              mtime: mtime, added: added)
    }

    @Test func memberCountsSortBothDirectionsAndBreakTiesByTitle() {
        let entries = [e("single", title: "B"), e("large", title: "C"), e("empty", title: "A"), e("small", title: "D")]
        let counts = ["large": 12, "small": 2, "empty": 0]
        let descending = sortEntries(entries, by: [.init(field: .memberCount, dir: .desc), .init(field: .title, dir: .asc)], memberCounts: counts)
        #expect(descending.map(\.path) == ["large", "small", "empty", "single"])
        let ascending = sortEntries(entries, by: [.init(field: .memberCount, dir: .asc)], memberCounts: counts)
        #expect(ascending.map(\.path) == ["single", "empty", "small", "large"])
        #expect(SortField.memberCount.defaultDir == .desc)
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
