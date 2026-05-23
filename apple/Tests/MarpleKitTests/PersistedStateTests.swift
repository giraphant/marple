import Testing
import Foundation
@testable import MarpleKit

@Suite struct DomainCodableTests {
    @Test func paneRoundTrips() throws {
        let cases: [Pane] = [.type(.paperAnalysis), .type(.other("weird")),
                             .themesIndex, .theme("现象学"), .trash]
        for p in cases {
            let data = try JSONEncoder().encode(p)
            #expect(try JSONDecoder().decode(Pane.self, from: data) == p)
        }
    }

    @Test func sortAndFilterClausesRoundTrip() throws {
        let sorts = [SortClause(field: .rating, dir: .desc), SortClause(field: .title, dir: .asc)]
        let filters = [FilterClause(id: "a", field: .year, op: .gte, value: "2000"),
                       FilterClause(id: "b", field: .haspdf, op: .yes, value: "")]
        let sd = try JSONEncoder().encode(sorts)
        let fd = try JSONEncoder().encode(filters)
        #expect(try JSONDecoder().decode([SortClause].self, from: sd) == sorts)
        #expect(try JSONDecoder().decode([FilterClause].self, from: fd) == filters)
        #expect(try JSONDecoder().decode(FilterMatch.self,
                from: JSONEncoder().encode(FilterMatch.any)) == .any)
    }

    @Test func navLocationRoundTrips() throws {
        let loc = NavLocation(pane: .theme("X"), openPath: "vault/a.md")
        let data = try JSONEncoder().encode(loc)
        #expect(try JSONDecoder().decode(NavLocation.self, from: data) == loc)
    }
}

@Suite struct WorkspaceRestoreTests {
    @Test func restoringBuildsTabsAndActive() throws {
        let ws = try #require(Workspace(restoring: [
            (NavLocation(pane: .type(.paperAnalysis)), false),
            (NavLocation(pane: .theme("X"), openPath: "v/a.md"), true),
        ], activeIndex: 1))
        #expect(ws.tabs.count == 2)
        #expect(ws.tabs[1].pinned)
        #expect(ws.activeTab.location.openPath == "v/a.md")
    }

    @Test func restoringEmptyReturnsNil() {
        #expect(Workspace(restoring: [], activeIndex: 0) == nil)
    }

    @Test func restoringClampsActiveIndex() throws {
        let ws = try #require(Workspace(restoring: [
            (NavLocation(pane: .trash), false),
        ], activeIndex: 9))
        #expect(ws.activeTab.location.pane == .trash)
    }

    @Test func pruneNullsMissingOpenPaths() throws {
        var ws = try #require(Workspace(restoring: [
            (NavLocation(pane: .type(.bookOverview), openPath: "gone.md"), false),
            (NavLocation(pane: .type(.bookOverview), openPath: "keep.md"), false),
        ], activeIndex: 0))
        ws.pruneOpenPaths(validPaths: ["keep.md"])
        #expect(ws.tabs[0].location.openPath == nil)
        #expect(ws.tabs[1].location.openPath == "keep.md")
    }

    @Test func replaceCurrentSwapsActiveEntry() {
        var h = NavHistory(NavLocation(pane: .trash, openPath: "x"))
        h.replaceCurrent(with: NavLocation(pane: .trash, openPath: nil))
        #expect(h.current.openPath == nil)
    }
}
