import Testing
@testable import MarpleKit

@Suite struct ThemeIndexTests {
    func e(_ path: String, _ themes: [String]) -> Entry {
        Entry(path: path, type: .paperAnalysis, title: nil, author: [], year: nil,
              ratingScore: 0, themes: themes, preview: "", hasPDF: false)
    }

    @Test func testCountsAndOrder() {
        let list = [e("a", ["econ", "history"]), e("b", ["econ"]), e("c", ["history"]),
                    e("d", ["econ"])]
        let idx = themeCounts(list)
        // econ:3 first (count desc), then history:2
        #expect(idx.map(\.theme) == ["econ", "history"])
        #expect(idx.map(\.count) == [3, 2])
    }

    @Test func testEqualCountsSortByName() {
        let list = [e("a", ["banana"]), e("b", ["apple"])]
        #expect(themeCounts(list).map(\.theme) == ["apple", "banana"])
    }

    @Test func testIgnoresEmptyThemeStrings() {
        let list = [e("a", ["", "  ", "econ"])]
        #expect(themeCounts(list).map(\.theme) == ["econ"])
    }
}
