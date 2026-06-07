import Testing
@testable import MarpleKit

@Suite struct BrowseTests {
    func e(_ path: String, _ type: EntryType, themes: [String] = []) -> Entry {
        Entry(path: path, type: type, title: nil, author: [], year: nil,
              ratingScore: 0, themes: themes, preview: "", hasPDF: false)
    }

    @Test func testTypePaneKeepsType() {
        let list = [e("a", .paper), e("b", .note), e("c", .paper)]
        #expect(entriesForPane(.type(.paper), in: list).map(\.path) == ["a", "c"])
    }

    @Test func testThemePaneKeepsThemeAcrossTypes() {
        let list = [e("a", .paper, themes: ["econ"]),
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

    // MARK: - Topic fold (QUA-189)

    func topic(_ path: String, kind: String? = nil) -> Entry {
        Entry(path: path, type: .topic, title: nil, author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false, kind: kind)
    }

    @Test func topicPaneFoldsToOneOverviewPerSlug() {
        let list = [
            topic("vault/topics/repair/00-overview.md", kind: "overview"),
            topic("vault/topics/repair/01-resources.md", kind: "resources"),
            topic("vault/topics/repair/02-resources.md", kind: "resources"),
            topic("vault/topics/crypto/00-overview.md", kind: "overview"),
            e("vault/papers/p.md", .paper),
        ]
        let paths = Set(entriesForPane(.type(.topic), in: list).map(\.path))
        #expect(paths == [
            "vault/topics/repair/00-overview.md",
            "vault/topics/crypto/00-overview.md",
        ])
    }

    @Test func topicPaneFallsBackToPathFirstWhenNoOverviewKind() {
        let list = [
            topic("vault/topics/x/02-b.md", kind: "resources"),
            topic("vault/topics/x/01-a.md", kind: "resources"),
        ]
        #expect(entriesForPane(.type(.topic), in: list).map(\.path) == ["vault/topics/x/01-a.md"])
    }

    @Test func nonTopicPanesUnaffectedByFold() {
        // A topic-typed entry must not leak into other type buckets.
        let list = [topic("vault/topics/x/00-overview.md", kind: "overview"), e("a", .paper)]
        #expect(entriesForPane(.type(.paper), in: list).map(\.path) == ["a"])
    }
}
