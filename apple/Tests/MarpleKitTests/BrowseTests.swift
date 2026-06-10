import Foundation
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

    // MARK: - Saved views (QUA-127)

    /// The saved-view universe is every entry with topics folded to overview
    /// rows — so a `类型 是 专题` view matches the 专题 bucket, never loose
    /// resource pages.
    @Test func savedViewPaneUsesBrowseUniverse() {
        let list = [
            e("vault/papers/p.md", .paper),
            e("vault/notes/n.md", .note),
            topic("vault/topics/repair/00-overview.md", kind: "overview"),
            topic("vault/topics/repair/01-resources.md", kind: "resources"),
        ]
        let universe = entriesForPane(.savedView(UUID()), in: list)
        #expect(Set(universe.map(\.path)) == [
            "vault/papers/p.md", "vault/notes/n.md", "vault/topics/repair/00-overview.md",
        ])
        // Composed with a type clause, the fold carries through.
        let topicsOnly = applyFilters(universe,
                                      [FilterClause(field: .type, op: .is_, value: "topic")],
                                      match: .all)
        #expect(topicsOnly.map(\.path) == ["vault/topics/repair/00-overview.md"])
    }

    @Test func savedViewRoundTripsThroughCodable() throws {
        let view = SavedView(name: "好论文",
                             clauses: [FilterClause(field: .type, op: .is_, value: "paper"),
                                       FilterClause(field: .rating, op: .gte, value: "4")],
                             match: .all,
                             sorts: [SortClause(field: .year, dir: .desc)])
        let data = try JSONEncoder().encode(view)
        let back = try JSONDecoder().decode(SavedView.self, from: data)
        #expect(back == view)
        // The pane case that references it round-trips too (it's in NavLocation).
        let pane = Pane.savedView(view.id)
        let paneBack = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
        #expect(paneBack == pane)
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
