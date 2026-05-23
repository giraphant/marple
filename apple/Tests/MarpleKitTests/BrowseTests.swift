import Testing
@testable import MarpleKit

@Suite struct BrowseTests {
    func e(_ path: String, _ type: EntryType, themes: [String] = []) -> Entry {
        Entry(path: path, type: type, title: nil, author: nil, year: nil,
              ratingScore: 0, themes: themes, preview: "", hasPDF: false)
    }

    @Test func testTypePaneKeepsType() {
        let list = [e("a", .paperAnalysis), e("b", .note), e("c", .paperAnalysis)]
        #expect(entriesForPane(.type(.paperAnalysis), in: list).map(\.path) == ["a", "c"])
    }

    @Test func testThemePaneKeepsThemeAcrossTypes() {
        let list = [e("a", .paperAnalysis, themes: ["econ"]),
                    e("b", .note, themes: ["econ"]),
                    e("c", .note, themes: ["history"])]
        #expect(entriesForPane(.theme("econ"), in: list).map(\.path) == ["a", "b"])
    }

    @Test func testThemesIndexPaneHasNoList() {
        #expect(entriesForPane(.themesIndex, in: [e("a", .note)]).isEmpty)
    }

    @Test func testTrashPaneHasNoEntries() {
        #expect(entriesForPane(.trash, in: [e("a", .note)]).isEmpty)
    }
}
