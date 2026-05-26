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
        let tabs: [(location: NavLocation, pinned: Bool)] = []
        #expect(Workspace(restoring: tabs, activeIndex: 0) == nil)
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

@Suite struct PersistedStateTests {
    private func sample() -> PersistedState {
        PersistedState(
            browsePane: .type(.paperAnalysis),
            isBrowsing: false,
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paperAnalysis), openPath: "v/x.md"), pinned: false),
                   PersistedTab(location: NavLocation(pane: .theme("X"), openPath: "v/a.md"), pinned: true)],
            activeIndex: 1,
            sortClauses: [SortClause(field: .rating, dir: .desc)],
            filterClauses: [FilterClause(id: "a", field: .year, op: .gte, value: "2000")],
            filterMatch: .any,
            browseMode: "list")
    }

    @Test func roundTripsThroughJSON() throws {
        let s = sample()
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(PersistedState.self, from: data) == s)
    }

    @Test func makeWorkspaceRebuildsActiveAndPinned() throws {
        let ws = try #require(sample().makeWorkspace())
        #expect(ws.tabs.count == 2)
        #expect(ws.activeTab.location.openPath == "v/a.md")
        #expect(ws.tabs[1].pinned)
    }

    @Test func makeWorkspaceRestoresTabTitles() throws {
        let s = PersistedState(
            browsePane: .type(.paperAnalysis),
            isBrowsing: false,
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paperAnalysis), openPath: "v/x.md"), pinned: false, customTitle: "Desk")],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "grid")
        let ws = try #require(s.makeWorkspace())
        #expect(ws.activeTab.customTitle == "Desk")
    }

    @Test func makeWorkspaceRestoresDefaultSpaceGroups() throws {
        let s = PersistedState(
            browsePane: .type(.paperAnalysis),
            isBrowsing: false,
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paperAnalysis), openPath: "v/x.md"), pinned: false),
                   PersistedTab(location: NavLocation(pane: .theme("X"), openPath: "v/a.md"), pinned: true),
                   PersistedTab(location: NavLocation(pane: .trash), pinned: false)],
            activeIndex: 1,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "grid",
            currentSpace: PersistedWorkspaceSpace(groups: [
                WorkspaceGroupSnapshot(name: "页面组 1", tabIndices: [0, 1], isCollapsed: true)
            ]))
        let data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(PersistedState.self, from: data)
        let ws = try #require(restored.makeWorkspace())
        let group = try #require(ws.tabGroups.first)
        #expect(group.name == "页面组 1")
        #expect(group.isCollapsed)
        #expect(ws.tabs(in: group.id).map(\.location.openPath) == ["v/x.md", "v/a.md"])
    }

    @Test func makeWorkspaceMigratesOldGeneratedGroupNames() throws {
        let s = PersistedState(
            browsePane: .type(.paperAnalysis),
            isBrowsing: false,
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paperAnalysis), openPath: "v/x.md"), pinned: false),
                   PersistedTab(location: NavLocation(pane: .theme("X"), openPath: "v/a.md"), pinned: true)],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "grid",
            currentSpace: PersistedWorkspaceSpace(groups: [
                WorkspaceGroupSnapshot(name: "标签组 2", tabIndices: [0, 1])
            ]))
        let ws = try #require(s.makeWorkspace())
        #expect(ws.tabGroups.first?.name == "页面组 2")
    }

    private func tabsFor(_ n: Int) -> [PersistedTab] {
        (0..<n).map { PersistedTab(location: NavLocation(pane: .type(.note), openPath: "t\($0).md"), pinned: false) }
    }

    private func state(tabs: [PersistedTab], tree: WorkspaceTreeSnapshot) -> PersistedState {
        PersistedState(browsePane: .type(.note), isBrowsing: false, tabs: tabs, activeIndex: 0,
                       sortClauses: [], filterClauses: [], filterMatch: .all, browseMode: "list",
                       currentSpace: PersistedWorkspaceSpace(tree: tree))
    }

    @Test func makeWorkspaceRestoresNestedTree() throws {
        let tree = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "Outer", isCollapsed: false, children: [
                .tab(0), .tab(1),
                .group(.init(name: "Inner", isCollapsed: true, children: [.tab(2), .tab(3)])),
            ])),
        ])
        let s = state(tabs: tabsFor(4), tree: tree)
        let data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(PersistedState.self, from: data)
        let ws = try #require(restored.makeWorkspace())

        #expect(ws.tabs.count == 4)
        let outer = try #require(ws.tabGroups.first { $0.name == "Outer" })
        #expect(outer.children.count == 3)
        let inner = try #require(ws.tabGroups.first { $0.name == "Inner" })
        #expect(inner.isCollapsed)
        #expect(ws.group(containing: ws.tabs[2].id)?.id == inner.id)
        #expect(ws.tabs(in: inner.id).map(\.location.openPath) == ["t2.md", "t3.md"])
        #expect(ws.tabs.map(\.location.openPath) == ["t0.md", "t1.md", "t2.md", "t3.md"])
    }

    @Test func makeWorkspaceDropsStaleLeavesAndKeepsOrphans() throws {
        // Tree references an out-of-range tab index; tab 2 is absent from the tree.
        let tree = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "G", isCollapsed: false, children: [.tab(0), .tab(1), .tab(9)])),
        ])
        let s = state(tabs: tabsFor(3), tree: tree)
        let ws = try #require(s.makeWorkspace())
        // stale index 9 dropped; orphan tab 2 appended at root; every tab present once.
        #expect(ws.tabs.count == 3)
        #expect(Set(ws.tabs.map(\.location.openPath)) == ["t0.md", "t1.md", "t2.md"])
        let g = try #require(ws.tabGroups.first)
        #expect(g.tabIDs.count == 2)
        #expect(ws.group(containing: ws.tabs.first { $0.location.openPath == "t2.md" }!.id) == nil)
    }

    @Test func makeWorkspacePrefersTreeOverLegacyGroups() throws {
        let tree = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "TreeGroup", isCollapsed: false, children: [.tab(0), .tab(1)])),
        ])
        var space = PersistedWorkspaceSpace(groups: [WorkspaceGroupSnapshot(name: "LegacyGroup", tabIndices: [0, 1])])
        space.tree = tree
        let s = PersistedState(browsePane: .type(.note), isBrowsing: false, tabs: tabsFor(2), activeIndex: 0,
                               sortClauses: [], filterClauses: [], filterMatch: .all, browseMode: "list",
                               currentSpace: space)
        let ws = try #require(s.makeWorkspace())
        #expect(ws.tabGroups.first?.name == "TreeGroup")
    }

    @Test func userDefaultsStoreRoundTrips() throws {
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        #expect(store.load() == nil)
        store.save(sample())
        #expect(store.load() == sample())
    }
}
