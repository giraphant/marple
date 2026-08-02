import Testing
import Foundation
@testable import MarpleKit

@Suite struct DomainCodableTests {
    @Test func paneRoundTrips() throws {
        let cases: [Pane] = [.type(.paper), .type(.other("weird")),
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
        let loc = NavLocation(pane: .theme("X"), openPath: "vault/a.md", searchText: "agency")
        let data = try JSONEncoder().encode(loc)
        #expect(try JSONDecoder().decode(NavLocation.self, from: data) == loc)
    }

    @Test func legacyNavLocationDecodesWithoutSearchText() throws {
        let current = NavLocation(pane: .type(.paper), openPath: "vault/a.md", searchText: "agency")
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        json.removeValue(forKey: "searchText")
        let decoded = try JSONDecoder().decode(
            NavLocation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.searchText == nil)
        #expect(decoded.openPath == "vault/a.md")
    }
}

@Suite struct WorkspaceRestoreTests {
    @Test func restoringBuildsTabsAndActive() throws {
        let ws = try #require(Workspace(restoring: [
            (NavLocation(pane: .type(.paper)), false),
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
            (NavLocation(pane: .type(.book), openPath: "gone.md", searchText: "agency"), false),
            (NavLocation(pane: .type(.book), openPath: "keep.md"), false),
        ], activeIndex: 0))
        ws.pruneOpenPaths(validPaths: ["keep.md"])
        #expect(ws.tabs[0].location.openPath == nil)
        #expect(ws.tabs[0].location.searchText == "agency")
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
            browsePane: .type(.paper),
            isBrowsing: false,
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paper), openPath: "v/x.md"), pinned: false),
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

    @Test func savedViewsRoundTripAndOldBlobsDecodeWithoutThem() throws {
        var s = sample()
        s.savedViews = [SavedView(name: "好论文",
                                  clauses: [FilterClause(field: .type, op: .is_, value: "paper")],
                                  match: .all,
                                  sorts: [SortClause(field: .year, dir: .desc)])]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(PersistedState.self, from: data) == s)
        // A blob persisted before QUA-127 has no savedViews key — must still decode.
        let old = try JSONEncoder().encode(sample())
        #expect(try JSONDecoder().decode(PersistedState.self, from: old).savedViews == nil)
    }

    @Test func makeWorkspaceRebuildsActiveAndPinned() throws {
        let ws = try #require(sample().makeWorkspace())
        #expect(ws.tabs.count == 2)
        #expect(ws.activeTab.location.openPath == "v/a.md")
        #expect(ws.tabs[1].pinned)
    }

    @Test func makeWorkspaceRestoresTabTitles() throws {
        let s = PersistedState(
            browsePane: .type(.paper),
            isBrowsing: false,
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paper), openPath: "v/x.md"), pinned: false, customTitle: "Desk")],
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
            browsePane: .type(.paper),
            isBrowsing: false,
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paper), openPath: "v/x.md"), pinned: false),
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
            browsePane: .type(.paper),
            isBrowsing: false,
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paper), openPath: "v/x.md"), pinned: false),
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

    @Test func makeSpacesRoundTripsMultipleIndependentSpaces() throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstTree = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "First", isCollapsed: true, children: [.tab(0), .tab(1)])),
        ])
        let secondTree = WorkspaceTreeSnapshot(roots: [
            .tab(0),
            .group(.init(name: "Second", isCollapsed: false, children: [.tab(1), .tab(2)])),
        ])
        let s = PersistedState(
            browsePane: .type(.note),
            isBrowsing: false,
            tabs: [],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "list",
            spaces: [
                PersistedWorkspaceSpace(id: firstID, name: "Alpha", isBrowsing: false, tabs: tabsFor(2), activeIndex: 1, tree: firstTree),
                PersistedWorkspaceSpace(id: secondID, name: "Beta", isBrowsing: true, tabs: tabsFor(3), activeIndex: 2, tree: secondTree),
            ],
            activeSpaceID: secondID)

        let data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(PersistedState.self, from: data)
        let made = restored.makeSpaces()

        #expect(made.activeID == secondID)
        #expect(made.spaces.map(\.id) == [firstID, secondID])
        #expect(made.spaces.map(\.name) == ["Alpha", "Beta"])
        #expect(made.spaces.map(\.isBrowsing) == [false, true])
        let firstWorkspace = try #require(made.spaces[0].workspace)
        #expect(firstWorkspace.activeTab.location.openPath == "t1.md")
        #expect(firstWorkspace.tabGroups.first?.isCollapsed == true)
        let secondWorkspace = try #require(made.spaces[1].workspace)
        #expect(secondWorkspace.activeTab.location.openPath == "t2.md")
        #expect(secondWorkspace.tabs.map(\.location.openPath) == ["t0.md", "t1.md", "t2.md"])
        let activeWorkspace = try #require(restored.makeWorkspace())
        #expect(activeWorkspace.activeTab.location.openPath == "t2.md")
    }

    @Test func makeSpacesRestoresLegacySingleSpaceFieldsAsDefaultSpace() throws {
        let s = PersistedState(
            browsePane: .type(.paper),
            isBrowsing: true,
            tabs: [PersistedTab(location: NavLocation(pane: .type(.paper), openPath: "legacy.md"), pinned: true)],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "grid",
            currentSpace: PersistedWorkspaceSpace(name: "Legacy", groups: []))

        let made = s.makeSpaces()

        #expect(made.spaces.count == 1)
        #expect(made.activeID == made.spaces.first?.id)
        let space = try #require(made.spaces.first)
        #expect(space.name == "Legacy")
        #expect(space.isBrowsing)
        let workspace = try #require(space.workspace)
        #expect(workspace.tabs.first?.location.openPath == "legacy.md")
        #expect(workspace.tabs.first?.pinned == true)
    }

    @Test func emptySpaceRoundTripsAndRestoresNilWorkspace() throws {
        let id = UUID()
        let s = PersistedState(
            browsePane: .type(.note),
            isBrowsing: false,
            tabs: [],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "list",
            spaces: [PersistedWorkspaceSpace(id: id, name: "Empty", isBrowsing: true, tabs: [], activeIndex: 0)],
            activeSpaceID: id)

        let data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(PersistedState.self, from: data)
        let made = restored.makeSpaces()

        #expect(made.activeID == id)
        let space = try #require(made.spaces.first)
        #expect(space.id == id)
        #expect(space.name == "Empty")
        #expect(space.isBrowsing)
        #expect(space.workspace == nil)
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

    // MARK: - cachedTitle / counts (QUA-105 follow-up)

    @Test func persistedTabCachedTitleRoundTrips() throws {
        let tab = PersistedTab(
            location: NavLocation(pane: .type(.note), openPath: "v/n.md"),
            pinned: false,
            customTitle: nil,
            cachedTitle: "Real Title")
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: data)
        #expect(decoded.cachedTitle == "Real Title")
    }

    @Test func persistedTabLegacyJSONDecodesWithNilCachedTitle() throws {
        // State written before the cachedTitle field existed must still decode
        // cleanly (no key in JSON → nil). Build the legacy payload by encoding
        // a current PersistedTab then stripping `cachedTitle` from the dict —
        // this stays robust against any future tweak to the Pane wire format
        // (which would have invalidated a hand-rolled JSON literal).
        let tab = PersistedTab(
            location: NavLocation(pane: .type(.note), openPath: "v/n.md"),
            pinned: false)
        let data = try JSONEncoder().encode(tab)
        var dict = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "cachedTitle")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: legacy)
        #expect(decoded.cachedTitle == nil)
        #expect(decoded.customTitle == nil)
        #expect(decoded.location.openPath == "v/n.md")
    }

    @Test func persistedStateCountsRoundTrip() throws {
        var s = sample()
        s.counts = [.note: 12, .paper: 47, .book: 3]
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        #expect(decoded.counts == s.counts)
    }

    @Test func persistedStateLegacyJSONDecodesWithNilCounts() throws {
        // Old PersistedState blobs (no `counts` key) must decode without
        // failing the whole load — that would silently wipe user state.
        let s = sample()
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        #expect(decoded.counts == nil)
    }

    @Test func makeWorkspaceCarriesCachedTitleIntoNavTab() throws {
        let s = PersistedState(
            browsePane: .type(.note),
            isBrowsing: false,
            tabs: [PersistedTab(
                location: NavLocation(pane: .type(.note), openPath: "v/a.md"),
                pinned: false,
                customTitle: nil,
                cachedTitle: "Cached Title")],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "list")
        let ws = try #require(s.makeWorkspace())
        #expect(ws.tabs.first?.cachedTitle == "Cached Title")
    }
}
