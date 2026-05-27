import Testing
import Foundation
@testable import MarpleKit

@Suite struct NavHistoryTests {
    let a = NavLocation(pane: .type(.note))
    let b = NavLocation(pane: .type(.paperAnalysis), openPath: "x.md")
    let c = NavLocation(pane: .theme("econ"))

    @Test func testInitialHasNoBackOrForward() {
        let h = NavHistory(a)
        #expect(h.current == a)
        #expect(!h.canGoBack)
        #expect(!h.canGoForward)
    }

    @Test func testPushAdvancesAndSetsCurrent() {
        var h = NavHistory(a)
        h.push(b)
        #expect(h.current == b)
        #expect(h.canGoBack)
        #expect(!h.canGoForward)
    }

    @Test func testPushOfCurrentIsNoOp() {
        var h = NavHistory(a)
        h.push(a)
        #expect(!h.canGoBack)
        #expect(h.current == a)
    }

    @Test func testBackAndForwardMove() {
        var h = NavHistory(a)
        h.push(b)
        h.back()
        #expect(h.current == a)
        #expect(h.canGoForward)
        h.forward()
        #expect(h.current == b)
    }

    @Test func testBackAtStartIsClamped() {
        var h = NavHistory(a)
        h.back()
        #expect(h.current == a)
        #expect(!h.canGoBack)
    }

    @Test func testForwardAtEndIsClamped() {
        var h = NavHistory(a)
        h.push(b)
        h.forward()
        #expect(h.current == b)
        #expect(!h.canGoForward)
    }

    @Test func testPushAfterBackTruncatesForward() {
        var h = NavHistory(a)
        h.push(b)
        h.back()            // at a, forward available (b)
        h.push(c)           // should drop b
        #expect(h.current == c)
        #expect(!h.canGoForward)
        h.back()
        #expect(h.current == a)
        h.forward()
        #expect(h.current == c) // not b — b was truncated
    }
}

@Suite struct WorkspaceTests {
    let a = NavLocation(pane: .type(.note))
    let b = NavLocation(pane: .type(.paperAnalysis), openPath: "x.md")
    let c = NavLocation(pane: .theme("econ"))

    @Test func testInitHasOneActiveTab() {
        let w = Workspace(initial: a)
        #expect(w.tabs.count == 1)
        #expect(w.activeTab.location == a)
        #expect(w.activeID == w.tabs[0].id)
    }

    @Test func testNavigateActiveOnlyTouchesActiveTab() {
        var w = Workspace(initial: a)
        let firstID = w.activeID
        w.newTab(b)                 // appends + activates new tab
        w.navigateActive(to: c)     // pushes onto the new (active) tab
        let first = w.tabs.first { $0.id == firstID }!
        #expect(first.location == a)            // untouched
        #expect(!first.history.canGoBack)
        #expect(w.activeTab.location == c)
        #expect(w.activeTab.history.canGoBack)  // b -> c
    }

    @Test func testNewTabAppendsAndActivates() {
        var w = Workspace(initial: a)
        w.newTab(b)
        #expect(w.tabs.count == 2)
        #expect(w.tabs.last?.location == b)
        #expect(w.activeTab.location == b)
    }

    @Test func testNewTabWithoutActivateKeepsActive() {
        var w = Workspace(initial: a)
        let id = w.newTab(b, activate: false)
        #expect(w.tabs.count == 2)
        #expect(w.activeTab.location == a)
        #expect(w.tabs.contains { $0.id == id })
    }

    @Test func testCloseActiveTabActivatesNeighbor() {
        var w = Workspace(initial: a)
        w.newTab(b)                 // [a, b], active b (index 1)
        w.newTab(c)                 // [a, b, c], active c (index 2)
        let bID = w.tabs[1].id
        w.select(bID)               // active b (index 1)
        w.closeTab(bID)             // remove index 1 -> [a, c]; active min(1, 1)=1 -> c
        #expect(w.tabs.map(\.location) == [a, c])
        #expect(w.activeTab.location == c)
    }

    @Test func testCloseLastIndexActivatesNewLast() {
        var w = Workspace(initial: a)
        w.newTab(b)                 // [a, b], active b (index 1)
        let bID = w.activeID
        w.closeTab(bID)             // remove last -> [a]; active min(1,0)=0 -> a
        #expect(w.tabs.map(\.location) == [a])
        #expect(w.activeTab.location == a)
    }

    @Test func testCloseInactiveTabKeepsActive() {
        var w = Workspace(initial: a)
        w.newTab(b)                 // [a, b], active b
        let aID = w.tabs[0].id
        w.closeTab(aID)             // remove inactive a -> [b]; active still b
        #expect(w.tabs.map(\.location) == [b])
        #expect(w.activeTab.location == b)
    }

    @Test func testSelectIndexInRangeAndOutOfRange() {
        var w = Workspace(initial: a)
        w.newTab(b); w.newTab(c)    // [a, b, c], active c
        w.selectIndex(0)
        #expect(w.activeTab.location == a)
        w.selectIndex(99)           // ignored
        #expect(w.activeTab.location == a)
    }

    @Test func testSelectRelativeWraps() {
        var w = Workspace(initial: a)
        w.newTab(b); w.newTab(c)    // [a, b, c], active c (index 2)
        w.selectRelative(1)         // wraps to index 0
        #expect(w.activeTab.location == a)
        w.selectRelative(-1)        // wraps to index 2
        #expect(w.activeTab.location == c)
    }

    @Test func testTogglePin() {
        var w = Workspace(initial: a)
        let id = w.activeID
        #expect(w.activeTab.pinned == false)
        w.togglePin(id)
        #expect(w.tabs.first { $0.id == id }?.pinned == true)
        w.togglePin(id)
        #expect(w.tabs.first { $0.id == id }?.pinned == false)
    }

    @Test func testReorderAppliesIdOrder() {
        var w = Workspace(initial: a)
        w.newTab(b); w.newTab(c)    // [a, b, c]
        let ids = [w.tabs[2].id, w.tabs[0].id, w.tabs[1].id]
        w.reorder(ids)
        #expect(w.tabs.map(\.location) == [c, a, b])
    }

    @Test func testRenameTabTrimsAndClearsEmptyTitle() {
        var w = Workspace(initial: a)
        let id = w.activeID
        w.renameTab(id, to: "  Workbench  ")
        #expect(w.activeTab.customTitle == "Workbench")
        w.renameTab(id, to: "   ")
        #expect(w.activeTab.customTitle == nil)
    }

    @Test func testReorderKeepsActiveAndIgnoresBadInput() {
        var w = Workspace(initial: a)
        w.newTab(b)                 // [a, b], active b
        let activeBefore = w.activeID
        w.reorder([w.tabs[1].id])   // incomplete -> no-op
        #expect(w.tabs.map(\.location) == [a, b])
        w.reorder([w.tabs[1].id, w.tabs[0].id])
        #expect(w.tabs.map(\.location) == [b, a])
        #expect(w.activeID == activeBefore)
    }

    @Test func testTabLocationReflectsHistoryCurrent() {
        var w = Workspace(initial: a)
        w.navigateActive(to: b)
        #expect(w.activeTab.location == b)
        w.backActive()
        #expect(w.activeTab.location == a)
        w.forwardActive()
        #expect(w.activeTab.location == b)
    }

    @Test func testGroupTabCreatesNamedGroupInTabOrder() throws {
        var w = Workspace(initial: a)
        w.newTab(b)
        w.newTab(c)
        let first = w.tabs[0].id
        let last = w.tabs[2].id
        w.groupTab(last, onto: first)
        let group = try #require(w.tabGroups.first)
        #expect(group.name == "页面组 1")
        #expect(group.tabIDs == [first, last])
    }

    @Test func testMoveTabIntoExistingGroupAndCollapse() throws {
        var w = Workspace(initial: a)
        w.newTab(b)
        w.newTab(c)
        let ids = w.tabs.map(\.id)
        w.groupTab(ids[0], onto: ids[1])
        let groupID = try #require(w.tabGroups.first?.id)
        w.moveTab(ids[2], toGroup: groupID)
        #expect(w.tabs(in: groupID).map(\.id) == [ids[1], ids[0], ids[2]])
        w.toggleGroupCollapsed(groupID)
        #expect(w.tabGroups.first?.isCollapsed == true)
    }

    @Test func testCloseTabDissolvesSmallGroup() throws {
        var w = Workspace(initial: a)
        w.newTab(b)
        let ids = w.tabs.map(\.id)
        w.groupTab(ids[0], onto: ids[1])
        #expect(w.tabGroups.count == 1)
        w.closeTab(ids[0])
        #expect(w.tabGroups.isEmpty)
        #expect(w.tabs.map(\.id) == [ids[1]])
    }

    @Test func testGroupingIgnoresBadInputAndSameGroupDrop() throws {
        var w = Workspace(initial: a)
        w.newTab(b)
        let ids = w.tabs.map(\.id)
        w.groupTab(ids[0], onto: ids[0])
        #expect(w.tabGroups.isEmpty)
        w.groupTab(ids[0], onto: ids[1])
        let before = w.tabGroups
        w.groupTab(ids[1], onto: ids[0])
        #expect(w.tabGroups == before)
    }

    @Test func testMoveTabIntoLaterGroupKeepsGroupPosition() throws {
        let d = NavLocation(pane: .trash)
        var w = Workspace(initial: a)
        w.newTab(b); w.newTab(c); w.newTab(d)
        let ids = w.tabs.map(\.id)
        w.groupTab(ids[3], onto: ids[2])
        let groupID = try #require(w.tabGroups.first?.id)
        w.moveTab(ids[0], toGroup: groupID, at: 1)
        #expect(w.tabs.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
        #expect(w.tabs(in: groupID).map(\.id) == [ids[2], ids[0], ids[3]])
    }

    @Test func testMoveTabToRootRemovesGroupMembership() throws {
        var w = Workspace(initial: a)
        w.newTab(b); w.newTab(c)
        let ids = w.tabs.map(\.id)
        w.groupTab(ids[1], onto: ids[0])
        w.moveTabToRoot(ids[1], beforeTab: ids[2])
        #expect(w.tabGroups.isEmpty)
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids[2]])
    }

    @Test func testMoveGroupMovesWholeBlockBeforeTarget() throws {
        let d = NavLocation(pane: .trash)
        var w = Workspace(initial: a)
        w.newTab(b); w.newTab(c); w.newTab(d)
        let ids = w.tabs.map(\.id)
        w.groupTab(ids[1], onto: ids[0])
        let groupID = try #require(w.tabGroups.first?.id)
        w.moveGroup(groupID, beforeTab: ids[3])
        #expect(w.tabs.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
        #expect(w.tabs(in: groupID).map(\.id) == [ids[0], ids[1]])
    }

    @Test func testMoveGroupBeforeGroup() throws {
        let d = NavLocation(pane: .trash)
        var w = Workspace(initial: a)
        w.newTab(b); w.newTab(c); w.newTab(d)
        let ids = w.tabs.map(\.id)
        w.groupTab(ids[1], onto: ids[0])
        w.groupTab(ids[3], onto: ids[2])
        #expect(w.tabGroups.count == 2)
        let firstGroup = w.tabGroups[0].id
        let secondGroup = w.tabGroups[1].id
        w.moveGroup(secondGroup, beforeGroup: firstGroup)
        #expect(w.tabs.map(\.id) == [ids[2], ids[3], ids[0], ids[1]])
    }

    @Test func testRenameGroupTrimsAndIgnoresEmptyName() throws {
        var w = Workspace(initial: a)
        w.newTab(b)
        let ids = w.tabs.map(\.id)
        w.groupTab(ids[1], onto: ids[0])
        let groupID = try #require(w.tabGroups.first?.id)
        w.renameGroup(groupID, to: "  Reading Stack  ")
        #expect(w.tabGroups.first?.name == "Reading Stack")
        w.renameGroup(groupID, to: "   ")
        #expect(w.tabGroups.first?.name == "Reading Stack")
    }
}

@Suite struct NestedTabGroupTests {
    private func loc(_ i: Int) -> NavLocation { NavLocation(pane: .type(.note), openPath: "t\(i).md") }

    /// Build N tabs and return the workspace plus the ordered tab ids.
    private func workspace(_ n: Int) -> (Workspace, [NavTab.ID]) {
        var w = Workspace(initial: loc(0))
        for i in 1..<n { w.newTab(loc(i)) }
        return (w, w.tabs.map(\.id))
    }

    /// Two top-level groups G1=[0,1], G2=[2,3] over four tabs.
    private func twoGroups() throws -> (Workspace, [NavTab.ID], g1: TabGroup.ID, g2: TabGroup.ID) {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])
        w.groupTab(ids[3], onto: ids[2])
        let g1 = try #require(w.group(containing: ids[0])?.id)
        let g2 = try #require(w.group(containing: ids[2])?.id)
        return (w, ids, g1, g2)
    }

    @Test func nestGroupIntoGroupKeepsBothAndDFS() throws {
        var (w, ids, g1, g2) = try twoGroups()
        w.moveGroup(g2, intoGroup: g1)
        let outer = try #require(w.group(g1))
        #expect(outer.children.count == 3)
        #expect(outer.children.contains { $0.group?.id == g2 })
        #expect(w.group(g2) != nil)                          // survives, now nested
        #expect(w.group(containing: ids[2])?.id == g2)
        #expect(w.tabs.map(\.id) == ids)                     // depth-first order preserved
        #expect(w.tabGroups.count == 2)
    }

    @Test func nestGroupIntoOwnDescendantIsNoOp() throws {
        var (w, _, g1, g2) = try twoGroups()
        w.moveGroup(g2, intoGroup: g1)        // G1 -> [.. G2]
        let before = w.rootNodes
        w.moveGroup(g1, intoGroup: g2)        // cycle: G1 into its descendant G2
        #expect(w.rootNodes == before)
    }

    @Test func nestGroupIntoItselfIsNoOp() throws {
        var (w, _, g1, _) = try twoGroups()
        let before = w.rootNodes
        w.moveGroup(g1, intoGroup: g1)
        #expect(w.rootNodes == before)
    }

    @Test func dropTabOntoSiblingInSameGroupFormsSubgroup() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])               // G = [ids0, ids1]
        let g = try #require(w.group(containing: ids[0])?.id)
        w.moveTab(ids[2], toGroup: g)
        w.moveTab(ids[3], toGroup: g)                  // G = [ids0, ids1, ids2, ids3]
        w.groupTab(ids[0], onto: ids[1])               // same group, 4 children -> subgroup in place
        let gnow = try #require(w.group(g))
        #expect(gnow.children.count == 3)
        let sub = try #require(gnow.children[0].group)
        #expect(sub.tabIDs == [ids[1], ids[0]])
        #expect(gnow.children[1].tabID == ids[2])
        #expect(gnow.children[2].tabID == ids[3])
        #expect(w.group(containing: ids[0])?.id == sub.id)
    }

    @Test func dropTabOntoOnlySiblingInTwoTabGroupIsNoOpPreservingName() throws {
        var (w, ids) = workspace(2)
        w.groupTab(ids[0], onto: ids[1])               // G = [ids1, ids0]
        let g = try #require(w.group(containing: ids[0])?.id)
        w.renameGroup(g, to: "Reading Stack")
        let before = w.rootNodes
        w.groupTab(ids[1], onto: ids[0])               // same group, only 2 children -> no-op
        #expect(w.rootNodes == before)
        #expect(w.group(g)?.name == "Reading Stack")
    }

    @Test func dropTabOntoGroupedTabFormsSubgroupInPlace() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])              // G1 = [ids0, ids1] at root
        let g1 = try #require(w.group(containing: ids[0])?.id)
        w.groupTab(ids[3], onto: ids[1])              // target ids1 is INSIDE G1 -> subgroup forms in G1
        let g1now = try #require(w.group(g1))
        #expect(g1now.children.count == 2)
        #expect(g1now.children[0].tabID == ids[0])
        let sub = try #require(g1now.children[1].group)
        #expect(sub.children.count == 2)
        #expect(sub.tabIDs == [ids[1], ids[3]])
        #expect(w.group(containing: ids[3])?.id == sub.id)
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids[3], ids[2]])
    }

    @Test func dropTabOntoTabInsideDeepSubgroupFormsDeeperSubgroup() throws {
        var (w, ids, g1, g2) = try twoGroups()        // G1=[0,1], G2=[2,3]
        w.moveGroup(g2, intoGroup: g1)                // G1 -> [0,1, G2[2,3]]
        w.newTab(loc(4))
        let ids4 = w.tabs.first { $0.location == loc(4) }!.id
        w.groupTab(ids4, onto: ids[2])                // target inside G2 -> sub-sub-group [ids2, ids4] inside G2
        let g2now = try #require(w.group(g2))
        let deepest = try #require(g2now.children.compactMap(\.group).first)
        #expect(deepest.tabIDs == [ids[2], ids4])
        #expect(w.group(containing: ids4)?.id == deepest.id)
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids[2], ids4, ids[3]])
    }

    @Test func moveTabIntoNestedSubgroup() throws {
        var (w, ids, g1, g2) = try twoGroups()       // 4 tabs
        w.newTab(loc(4)); let ids4 = w.tabs.last!.id
        w.moveGroup(g2, intoGroup: g1)               // G1 -> [0,1,G2[2,3]], tab4 at root
        w.moveTab(ids4, toGroup: g2)
        #expect(w.group(containing: ids4)?.id == g2)
        #expect(w.group(g2)?.tabIDs == [ids[2], ids[3], ids4])
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids[2], ids[3], ids4])
    }

    @Test func moveDeepTabToRootDissolvesEmptiedSubgroup() throws {
        var (w, ids, g1, g2) = try twoGroups()
        w.moveGroup(g2, intoGroup: g1)               // G1 -> [0,1,G2[2,3]]
        w.moveTabToRoot(ids[2], beforeTab: nil)      // G2 -> [3] -> dissolves, 3 promoted into G1
        #expect(w.group(containing: ids[2]) == nil)
        #expect(w.group(g2) == nil)
        #expect(w.group(g1)?.tabIDs == [ids[0], ids[1], ids[3]])
        #expect(Set(w.tabs.map(\.id)) == Set(ids))
    }

    @Test func dissolveCascadePromotesNestedGroup() throws {
        var (w, ids, g1, g2) = try twoGroups()
        w.moveGroup(g2, intoGroup: g1)               // G1 -> [0,1,G2[2,3]]
        w.moveTabToRoot(ids[1], beforeTab: nil)      // G1 -> [0, G2]
        #expect(w.group(g1)?.children.count == 2)
        w.moveTabToRoot(ids[0], beforeTab: nil)      // G1 -> [G2] -> dissolves, G2 promoted to root
        #expect(w.group(g1) == nil)
        #expect(w.group(g2) != nil)
        #expect(w.group(g2)?.tabIDs == [ids[2], ids[3]])
    }

    @Test func moveTabReordersWithinGroup() throws {
        var (w, ids) = workspace(3)
        w.groupTab(ids[1], onto: ids[0])
        let g = try #require(w.group(containing: ids[0])?.id)
        w.moveTab(ids[2], toGroup: g)                // [0,1,2]
        #expect(w.tabs(in: g).map(\.id) == [ids[0], ids[1], ids[2]])
        w.moveTab(ids[2], toGroup: g, at: 0)         // [2,0,1]
        #expect(w.tabs(in: g).map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(w.tabs.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func moveTabDownWithinGroupUsesDropIndex() throws {
        var (w, ids) = workspace(3)
        w.groupTab(ids[1], onto: ids[0])
        let g = try #require(w.group(containing: ids[0])?.id)
        w.moveTab(ids[2], toGroup: g)                // [0,1,2]
        // Drag tab0 to the slot between tab1 and tab2 — AppKit reports child index 2.
        w.moveTab(ids[0], toGroup: g, at: 2)
        #expect(w.tabs(in: g).map(\.id) == [ids[1], ids[0], ids[2]])
    }

    @Test func moveGroupBeforeNestedTabNestsIntoItsParent() throws {
        var (w, ids, g1, g2) = try twoGroups()       // G1=[0,1], G2=[2,3]
        w.newTab(loc(4)); w.newTab(loc(5))
        let ids4 = w.tabs.first { $0.location == loc(4) }!.id
        let ids5 = w.tabs.first { $0.location == loc(5) }!.id
        w.moveGroup(g2, intoGroup: g1)               // G1 -> [0,1,G2[2,3]]
        w.groupTab(ids5, onto: ids4)                 // new top-level group G3=[4,5]
        let g3 = try #require(w.group(containing: ids4)?.id)
        w.moveGroup(g3, beforeTab: ids[2])           // drop G3 before the nested tab 2
        #expect(w.group(containing: ids4)?.id == g3)
        #expect(w.group(g2)?.children.contains { $0.group?.id == g3 } == true)  // G3 nested inside G2
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids4, ids5, ids[2], ids[3]])
    }

    @Test func moveGroupToRootUnnests() throws {
        var (w, ids, g1, g2) = try twoGroups()
        w.moveGroup(g2, intoGroup: g1)               // G1 -> [0,1,G2[2,3]]
        w.moveGroupToRoot(g2, at: 0)                 // G2 back to root, before G1
        #expect(w.group(g2) != nil)
        #expect(w.group(containing: ids[2])?.id == g2)
        let outer = try #require(w.group(g1))
        #expect(outer.children.allSatisfy { $0.group == nil })   // G1 holds only tabs again
        #expect(w.tabs.map(\.id) == [ids[2], ids[3], ids[0], ids[1]])
    }

    @Test func moveGroupToRootInsertsBesideNotInside() throws {
        var (w, ids, g1, g2) = try twoGroups()       // root: [G1, G2]
        w.moveGroupToRoot(g1, at: 2)                  // move G1 after G2 (downward at root)
        #expect(w.group(g1) != nil)
        #expect(w.group(g2) != nil)
        #expect(w.group(g1, isInsideSubtreeOf: g2) == false)   // not nested into G2
        #expect(w.group(g2, isInsideSubtreeOf: g1) == false)
        #expect(w.tabs.map(\.id) == [ids[2], ids[3], ids[0], ids[1]])
    }

    @Test func moveGroupBeforeOwnDescendantTabIsNoOp() throws {
        var (w, ids, g1, g2) = try twoGroups()
        w.moveGroup(g2, intoGroup: g1)               // G1 -> [0,1,G2[2,3]]
        let before = w.rootNodes
        w.moveGroup(g1, beforeTab: ids[2])           // ids2 is inside G1's subtree -> no-op
        #expect(w.rootNodes == before)
    }

    @Test func outermostCollapsedAncestorReportsVisibleRow() throws {
        var (w, ids, g1, g2) = try twoGroups()
        w.moveGroup(g2, intoGroup: g1)               // G1 -> [0,1,G2[2,3]]
        #expect(w.outermostCollapsedAncestor(of: ids[2]) == nil)
        w.setGroupCollapsed(g2, collapsed: true)
        #expect(w.outermostCollapsedAncestor(of: ids[2]) == g2)
        w.setGroupCollapsed(g1, collapsed: true)
        #expect(w.outermostCollapsedAncestor(of: ids[2]) == g1)   // outer wins
        #expect(w.outermostCollapsedAncestor(of: ids[0]) == g1)
    }

    @Test func closingNestedTabReconcilesTree() throws {
        var (w, ids, g1, g2) = try twoGroups()
        w.moveGroup(g2, intoGroup: g1)               // G1 -> [0,1,G2[2,3]]
        w.closeTab(ids[2])                           // G2 -> [3] -> dissolves
        #expect(w.group(g2) == nil)
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids[3]])
        #expect(w.group(g1)?.tabIDs == [ids[0], ids[1], ids[3]])
    }

    @Test func reorderResortsTreeKeepingGroupsContiguous() throws {
        var (w, ids, g1, g2) = try twoGroups()       // root: G1[0,1], G2[2,3]
        // Ask for an order that interleaves a G2 member before G1 -> groups snap contiguous.
        w.reorder([ids[2], ids[0], ids[1], ids[3]])
        // G2's earliest rank (0) < G1's earliest rank (1) -> G2 first; members keep contiguity.
        #expect(w.tabs.map(\.id) == [ids[2], ids[3], ids[0], ids[1]])
        #expect(w.group(g1)?.tabIDs == [ids[0], ids[1]])
        #expect(w.group(g2)?.tabIDs == [ids[2], ids[3]])
    }

    @Test func treeSnapshotRoundTripsThroughWorkspace() throws {
        var (w, ids, g1, g2) = try twoGroups()
        w.moveGroup(g2, intoGroup: g1)
        w.setGroupCollapsed(g2, collapsed: true)
        let snap = w.treeSnapshot
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WorkspaceTreeSnapshot.self, from: data)
        let restored = try #require(Workspace(
            restoring: w.tabs.map { (location: $0.location, pinned: $0.pinned, customTitle: $0.customTitle, cachedTitle: $0.cachedTitle) },
            activeIndex: 0,
            tree: decoded))
        #expect(restored.tabs.map(\.location) == w.tabs.map(\.location))
        let outer = try #require(restored.tabGroups.first)
        #expect(outer.children.count == 3)
        let inner = try #require(outer.children.compactMap(\.group).first)
        #expect(inner.isCollapsed)
        #expect(restored.tabs(in: inner.id).map(\.location) == [loc(2), loc(3)])
        _ = (ids, g1)
    }
}

@Suite struct BatchTabActionsTests {
    private func loc(_ i: Int) -> NavLocation { NavLocation(pane: .type(.note), openPath: "t\(i).md") }

    private func workspace(_ n: Int) -> (Workspace, [NavTab.ID]) {
        var w = Workspace(initial: loc(0))
        for i in 1..<n { w.newTab(loc(i)) }
        return (w, w.tabs.map(\.id))
    }

    @Test func closeTabsRemovesNonPinnedAndSkipsPinned() throws {
        var (w, ids) = workspace(4)
        w.togglePin(ids[1])                              // pin id 1
        w.closeTabs(Set([ids[0], ids[1], ids[3]]))       // ask to close 0, 1 (pinned), 3
        #expect(w.tabs.map(\.id) == [ids[1], ids[2]])    // only 0 and 3 close; 1 stays
    }

    @Test func closeTabsActivatesNeighborWhenActiveIsClosed() throws {
        var (w, ids) = workspace(4)
        w.select(ids[1])
        w.closeTabs(Set([ids[1], ids[2]]))
        #expect(w.tabs.map(\.id) == [ids[0], ids[3]])
        #expect(w.activeID == ids[3])                    // neighbor reactivation followed each removal
    }

    @Test func groupTabsPlacesNewGroupAtEarliestTabsPositionAndFlatOrder() throws {
        var (w, ids) = workspace(4)
        // group 0 + 2 → new group should sit where ids[0] was (root index 0)
        w.groupTabs([ids[2], ids[0]])                    // input order reversed; DFS order should win
        let group = try #require(w.tabGroups.first)
        #expect(w.rootNodes.first?.group?.id == group.id)
        #expect(group.tabIDs == [ids[0], ids[2]])        // DFS order = visual order
        // remaining root nodes: ids[1], ids[3] follow
        #expect(w.tabs.map(\.id) == [ids[0], ids[2], ids[1], ids[3]])
    }

    @Test func groupTabsAcrossParentsAnchorsAtRoot() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])                 // G = [ids0, ids1] at root[0]
        let g = try #require(w.tabGroups.first?.id)
        // ids[0] is in G, ids[2] is at root → no common group; new group anchors
        // at root[0] (root-level slot of the earliest's ancestor G). G keeps
        // ids[1] alone, dissolves.
        w.groupTabs([ids[0], ids[2]])
        #expect(w.group(g) == nil)                       // G dissolved (1 child left)
        #expect(w.tabGroups.count == 1)
        let new = try #require(w.tabGroups.first)
        #expect(new.tabIDs == [ids[0], ids[2]])
        // root order: new group, then orphaned ids[1], then ids[3]
        #expect(w.tabs.map(\.id) == [ids[0], ids[2], ids[1], ids[3]])
    }

    /// QUA-99: when the selection spans sibling groups under a common non-root
    /// ancestor, the new group lands inside that ancestor — not at root.
    @Test func groupTabsAcrossSiblingGroupsAnchorsAtCommonAncestor() throws {
        let tabSpecs = (0..<5).map { (location: loc($0), pinned: false, customTitle: String?.none, cachedTitle: String?.none) }
        let snap = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "G", isCollapsed: false, children: [
                .group(.init(name: "A", isCollapsed: false, children: [.tab(0), .tab(1)])),
                .group(.init(name: "B", isCollapsed: false, children: [.tab(2), .tab(3)])),
            ])),
            .tab(4),
        ])
        var w = try #require(Workspace(restoring: tabSpecs, activeIndex: 0, tree: snap))
        let ids = w.tabs.map(\.id)
        let g = try #require(w.tabGroups.first { $0.name == "G" }?.id)
        let bID = try #require(w.tabGroups.first { $0.name == "B" }?.id)

        // ids[0] is in G/A, ids[2] is in G/B → LCA is G. New group should sit
        // inside G at A's slot (the LCA child containing the earliest tab).
        w.groupTabs([ids[2], ids[0]])

        let newGroup = try #require(w.tabGroups.first { $0.id != g && $0.id != bID })
        let outer = try #require(w.group(g))
        // A dissolves (one child left after lift); B dissolves (one child left).
        // G now contains: [newGroup, ids1 (from A), ids3 (from B)].
        #expect(outer.children.first?.group?.id == newGroup.id)
        #expect(outer.tabIDs.dropFirst(0) == [ids[1], ids[3]])
        #expect(newGroup.tabIDs == [ids[0], ids[2]])
        #expect(w.tabs.map(\.id) == [ids[0], ids[2], ids[1], ids[3], ids[4]])
    }

    /// QUA-99: same-parent case still places the new group inside that parent
    /// at the earliest tab's slot — unchanged behavior.
    @Test func groupTabsSameNonRootParentAnchorsAtEarliestSlot() throws {
        let tabSpecs = (0..<4).map { (location: loc($0), pinned: false, customTitle: String?.none, cachedTitle: String?.none) }
        let snap = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "A", isCollapsed: false, children: [
                .tab(0), .tab(1), .tab(2),
            ])),
            .tab(3),
        ])
        var w = try #require(Workspace(restoring: tabSpecs, activeIndex: 0, tree: snap))
        let ids = w.tabs.map(\.id)
        let a = try #require(w.tabGroups.first?.id)
        w.groupTabs([ids[1], ids[0]])
        let newGroup = try #require(w.tabGroups.first { $0.id != a })
        let outer = try #require(w.group(a))
        #expect(outer.children.first?.group?.id == newGroup.id)
        #expect(newGroup.tabIDs == [ids[0], ids[1]])
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids[2], ids[3]])
    }

    /// QUA-99 coverage gap (Codex 5a): LCA at depth ≥3. Tabs identified by
    /// NavLocation since the restoring init re-orders `tabs` to DFS leaf order.
    /// Layout: G[H[J[t0, anchorJ], K[t1, anchorK]], t2]. groupTabs([t1, t0]) —
    /// paths [G, H, J] vs [G, H, K] → LCA = [G, H]. New group lands inside H
    /// at slot 0 (the slot of J, which contains earliest tab t0). J keeps its
    /// anchor; K keeps its anchor; both survive (≥2 children each? No — each
    /// has 1 child left and dissolves). Final H = [newGroup, anchorJ, anchorK].
    @Test func groupTabsAcrossDeeplyNestedSiblingsAnchorsAtLCA() throws {
        let l0 = loc(0); let l1 = loc(1); let lT2 = loc(2)
        let lAJ = loc(3); let lAK = loc(4)
        let tabSpecs: [(location: NavLocation, pinned: Bool, customTitle: String?, cachedTitle: String?)] =
            [l0, l1, lT2, lAJ, lAK].map { (location: $0, pinned: false, customTitle: nil, cachedTitle: nil) }
        let snap = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "G", isCollapsed: false, children: [
                .group(.init(name: "H", isCollapsed: false, children: [
                    .group(.init(name: "J", isCollapsed: false, children: [.tab(0), .tab(3)])),
                    .group(.init(name: "K", isCollapsed: false, children: [.tab(1), .tab(4)])),
                ])),
                .tab(2),
            ])),
        ])
        var w = try #require(Workspace(restoring: tabSpecs, activeIndex: 0, tree: snap))
        let tabID: (NavLocation) -> NavTab.ID = { loc in w.tabs.first { $0.location == loc }!.id }
        let t0 = tabID(l0), t1 = tabID(l1), tT2 = tabID(lT2), aJ = tabID(lAJ), aK = tabID(lAK)
        let h = try #require(w.tabGroups.first { $0.name == "H" }?.id)

        w.groupTabs([t1, t0])

        let hGroup = try #require(w.group(h))
        // J dissolves to anchorJ; K dissolves to anchorK; H = [newGroup, aJ, aK].
        #expect(hGroup.children.count == 3)
        let newGroup = try #require(hGroup.children[0].group)
        #expect(newGroup.tabIDs == [t0, t1])
        #expect(hGroup.children[1].tabID == aJ)
        #expect(hGroup.children[2].tabID == aK)
        // DFS leaf order: [t0, t1, anchorJ, anchorK, tT2].
        #expect(w.tabs.map(\.id) == [t0, t1, aJ, aK, tT2])
    }

    /// QUA-100 coverage gap (Codex 5b): moveItems when the destination group
    /// already contains some of the dragged items — verifies in-parent
    /// adjusted-index applies correctly to the mixed case.
    @Test func moveItemsIntoGroupWithExistingDraggedTabsReorders() throws {
        let tabSpecs = (0..<5).map { (location: loc($0), pinned: false, customTitle: String?.none, cachedTitle: String?.none) }
        let snap = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "Dst", isCollapsed: false, children: [.tab(0), .tab(1), .tab(2)])),
            .group(.init(name: "Sub", isCollapsed: false, children: [.tab(3), .tab(4)])),
        ])
        var w = try #require(Workspace(restoring: tabSpecs, activeIndex: 0, tree: snap))
        let ids = w.tabs.map(\.id)
        let dst = try #require(w.tabGroups.first { $0.name == "Dst" }?.id)
        let sub = try #require(w.tabGroups.first { $0.name == "Sub" }?.id)
        // Move [ids0 (already inside Dst at slot 0), Sub] into Dst at slot 2.
        // Adjustment: ids0 detaches from Dst at slot 0 < 2 → baseTarget = 1.
        // After detach: Dst = [ids1, ids2]. Insert ids0, then Sub at slots 1, 2.
        // Result: Dst = [ids1, ids0, Sub, ids2].
        w.moveItems([.tab(ids[0]), .group(sub)], toGroup: dst, at: 2)
        let dstGroup = try #require(w.group(dst))
        #expect(dstGroup.children.count == 4)
        #expect(dstGroup.children[0].tabID == ids[1])
        #expect(dstGroup.children[1].tabID == ids[0])
        #expect(dstGroup.children[2].group?.id == sub)
        #expect(dstGroup.children[3].tabID == ids[2])
        #expect(w.tabs.map(\.id) == [ids[1], ids[0], ids[3], ids[4], ids[2]])
    }

    /// QUA-100 coverage gap (Codex 5c): all-root group-only reorder via
    /// moveItemsToRoot. Confirms baseTarget adjustment when every source sits
    /// in the destination (root) at slots before the raw index.
    @Test func moveItemsToRootGroupOnlyReorderAdjustsBaseTarget() throws {
        let tabSpecs = (0..<4).map { (location: loc($0), pinned: false, customTitle: String?.none, cachedTitle: String?.none) }
        let snap = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "G1", isCollapsed: false, children: [.tab(0), .tab(1)])),
            .group(.init(name: "G2", isCollapsed: false, children: [.tab(2), .tab(3)])),
        ])
        var w = try #require(Workspace(restoring: tabSpecs, activeIndex: 0, tree: snap))
        let g1 = try #require(w.tabGroups.first { $0.name == "G1" }?.id)
        let g2 = try #require(w.tabGroups.first { $0.name == "G2" }?.id)
        // Move [G1, G2] to root at slot 2 (i.e., after current root.count == 2 → end).
        // Both detach from root at slots 0, 1 → both < 2 → baseTarget = 0.
        // Re-insert in supplied order at slots 0, 1 → root stays [G1, G2].
        let beforeIds = w.tabs.map(\.id)
        w.moveItemsToRoot([.group(g1), .group(g2)], at: 2)
        let roots = w.rootNodes.compactMap(\.group?.id)
        #expect(roots == [g1, g2])
        #expect(w.tabs.map(\.id) == beforeIds)
        // Now swap: [G2, G1] at end. G2 detaches from slot 1, G1 from slot 0,
        // raw 2, both < 2 → baseTarget = 0. Insert G2 at 0, G1 at 1 → [G2, G1].
        w.moveItemsToRoot([.group(g2), .group(g1)], at: 2)
        let rootsAfter = w.rootNodes.compactMap(\.group?.id)
        #expect(rootsAfter == [g2, g1])
    }

    @Test func groupTabsIgnoresLessThanTwoIDs() throws {
        var (w, ids) = workspace(3)
        let before = w.rootNodes
        w.groupTabs([ids[0]])                            // <2 → no-op
        #expect(w.rootNodes == before)
        w.groupTabs([ids[0], ids[0]])                    // duplicates collapse to <2 → no-op
        #expect(w.rootNodes == before)
    }

    @Test func moveTabsBulkIntoGroupPreservesInputOrder() throws {
        var (w, ids) = workspace(5)
        w.groupTab(ids[1], onto: ids[0])                 // G = [ids0, ids1]
        let g = try #require(w.tabGroups.first?.id)
        // append ids[4], ids[2] to G in that order at the end
        w.moveTabs([ids[4], ids[2]], toGroup: g, at: nil)
        #expect(w.tabs(in: g).map(\.id) == [ids[0], ids[1], ids[4], ids[2]])
        // depth-first ordering of remaining root: ids[3] before nothing else
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids[4], ids[2], ids[3]])
    }

    @Test func moveTabsAdjustsIndexForInGroupSources() throws {
        var (w, ids) = workspace(5)
        w.groupTab(ids[1], onto: ids[0])                 // G = [ids0, ids1]
        let g = try #require(w.tabGroups.first?.id)
        w.moveTab(ids[2], toGroup: g)                    // G = [ids0, ids1, ids2]
        w.moveTab(ids[3], toGroup: g)                    // G = [ids0, ids1, ids2, ids3]
        // ids4 is still at root; move (ids0, ids4) so they land between ids2 and ids3
        // childIndex = 3 (the slot of ids3 in G). ids0 lives at G[0] < 3, so it shifts.
        w.moveTabs([ids[0], ids[4]], toGroup: g, at: 3)
        let order = w.tabs(in: g).map(\.id)
        #expect(order == [ids[1], ids[2], ids[0], ids[4], ids[3]])
    }

    // MARK: phase 3 — multi-item drag

    @Test func moveTabsToRootDissolvesEmptiedSourceGroup() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])                 // G = [ids0, ids1] at root[0]
        // Lift both group members back to root at index 1. G empties and
        // dissolves; the new tabs occupy the positions where G used to sit.
        w.moveTabsToRoot([ids[0], ids[1]], at: 1)
        #expect(w.tabGroups.isEmpty)
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids[2], ids[3]])
    }

    @Test func moveTabsToRootKeepsPartiallyEmptiedGroupAlive() throws {
        var (w, ids) = workspace(6)
        w.groupTab(ids[1], onto: ids[0])                 // G = [ids0, ids1]
        let g = try #require(w.tabGroups.first?.id)
        w.moveTab(ids[2], toGroup: g)
        w.moveTab(ids[3], toGroup: g)                    // G = [ids0, ids1, ids2, ids3]
        // Root before move: [G, ids4, ids5]. Lift ids0 + ids1 to root index 1.
        // G keeps [ids2, ids3] → survives. Inserted at root[1] (after G).
        w.moveTabsToRoot([ids[0], ids[1]], at: 1)
        #expect(w.group(g) != nil)
        #expect(w.tabs(in: g).map(\.id) == [ids[2], ids[3]])
        #expect(w.tabs.map(\.id) == [ids[2], ids[3], ids[0], ids[1], ids[4], ids[5]])
    }

    @Test func moveTabsToRootAppendsWhenIndexIsNil() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])                 // G = [ids0, ids1]
        w.moveTabsToRoot([ids[0], ids[1]], at: nil)      // append at end
        #expect(w.tabs.map(\.id) == [ids[2], ids[3], ids[0], ids[1]])
    }

    @Test func moveGroupsToRootHoistsNestedGroupBack() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])                 // G1 = [ids0, ids1]
        w.groupTab(ids[3], onto: ids[2])                 // G2 = [ids2, ids3]
        let g1 = try #require(w.tabGroups.first?.id)
        let g2 = try #require(w.tabGroups.last?.id)
        w.moveGroup(g2, intoGroup: g1)                   // G1 = [ids0, ids1, G2]
        w.moveGroupsToRoot([g2], at: 0)                  // hoist G2 back, at root[0]
        // Now G1 has 2 children left; should not dissolve.
        #expect(w.group(g2) != nil)
        #expect(w.group(g1) != nil)
        // Root order: G2 first, then G1.
        let roots = w.rootNodes.compactMap(\.group?.id)
        #expect(roots == [g2, g1])
        // Tabs DFS: ids2, ids3 (from G2), then ids0, ids1 (from G1).
        #expect(w.tabs.map(\.id) == [ids[2], ids[3], ids[0], ids[1]])
    }

    @Test func payloadAncestorFilterDropsDescendantsOfSelectedGroups() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])                 // G = [ids0, ids1]
        let g = try #require(w.tabGroups.first?.id)
        // Selection: G + ids0 (descendant) + ids2 (independent).
        // ids0 must be dropped (G already moves it); G + ids2 remain.
        let result = w.payloadAncestorFilter(tabIDs: [ids[0], ids[2]], groupIDs: [g])
        #expect(result.tabs == [ids[2]])
        #expect(result.groups == [g])
    }

    // MARK: QUA-100 — interleaved order preservation

    @Test func moveItemsToRootPreservesInterleavedOrder() throws {
        var (w, ids) = workspace(5)
        w.groupTab(ids[1], onto: ids[0])                  // G = [ids0, ids1] at root[0]
        let g = try #require(w.tabGroups.first?.id)
        // Root before: [G, ids2, ids3, ids4]. Drop a tab/group/tab sequence at
        // root[0]. Visual order: ids2, G, ids4 → expect those three contiguously
        // at the head of root, in that exact order.
        w.moveItemsToRoot([.tab(ids[2]), .group(g), .tab(ids[4])], at: 0)
        let roots = w.rootNodes
        #expect(roots.count == 4)
        #expect(roots[0].tabID == ids[2])
        #expect(roots[1].group?.id == g)
        #expect(roots[2].tabID == ids[4])
        #expect(roots[3].tabID == ids[3])
        #expect(w.tabs(in: g).map(\.id) == [ids[0], ids[1]])
    }

    @Test func moveItemsToRootSkipsTabsBeforeGroupsWhenInterleaved() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])                  // G = [ids0, ids1]
        let g = try #require(w.tabGroups.first?.id)
        // Append [G, ids2] at end (preserving order): root → [_, ids3, G, ids2]
        // ... actually with G removed first: root = [ids3], then re-insert G, ids2 at end.
        w.moveItemsToRoot([.group(g), .tab(ids[2])], at: nil)
        let roots = w.rootNodes
        #expect(roots.compactMap(\.tabID) == [ids[3], ids[2]])
        #expect(roots[1].group?.id == g)
    }

    @Test func moveItemsIntoGroupPreservesInterleavedOrder() throws {
        // Dst needs ≥2 anchor tabs so it survives normalize after Src + ids4
        // land inside it; otherwise dissolveSmall would unwrap Dst.
        let tabSpecs = (0..<5).map { (location: loc($0), pinned: false, customTitle: String?.none, cachedTitle: String?.none) }
        let snap = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "Dst", isCollapsed: false, children: [.tab(0), .tab(1)])),
            .group(.init(name: "Src", isCollapsed: false, children: [.tab(2), .tab(3)])),
            .tab(4),
        ])
        var w = try #require(Workspace(restoring: tabSpecs, activeIndex: 0, tree: snap))
        let ids = w.tabs.map(\.id)
        let dst = try #require(w.tabGroups.first { $0.name == "Dst" }?.id)
        let src = try #require(w.tabGroups.first { $0.name == "Src" }?.id)
        // Drop [Src, ids4] into Dst at end. Order must be Src first, then ids4.
        w.moveItems([.group(src), .tab(ids[4])], toGroup: dst, at: nil)
        let dstGroup = try #require(w.group(dst))
        #expect(dstGroup.children.count == 4)
        #expect(dstGroup.children[0].tabID == ids[0])
        #expect(dstGroup.children[1].tabID == ids[1])
        #expect(dstGroup.children[2].group?.id == src)
        #expect(dstGroup.children[3].tabID == ids[4])
        #expect(w.tabs.map(\.id) == [ids[0], ids[1], ids[2], ids[3], ids[4]])
    }

    @Test func moveItemsSkipsCycleSilently() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])
        w.groupTab(ids[3], onto: ids[2])
        let g1 = try #require(w.tabGroups[0].id)
        let g2 = try #require(w.tabGroups[1].id)
        w.moveGroup(g2, intoGroup: g1)                    // G2 nested inside G1
        let before = w.rootNodes
        // Attempt to nest G1 into G2 (its own descendant) bundled with a tab.
        // The cycle group should be skipped; ids2 should still be moved.
        w.moveItems([.group(g1), .tab(ids[2])], toGroup: g2, at: nil)
        // G1 must NOT have been removed-and-not-reinserted; it stays where it was.
        // ids[2] is already inside G2 (since we nested G2 into G1 which contains
        // ids2 indirectly); moving ids2 into G2 is a no-op for its parent but
        // still legal — verify the tree isn't broken.
        #expect(w.group(g1) != nil)
        #expect(w.group(g2) != nil)
        #expect(w.group(g2, isInsideSubtreeOf: g1))       // still nested
        _ = before
    }

    @Test func payloadAncestorFilterDropsNestedGroupOfSelectedGroup() throws {
        var (w, ids) = workspace(4)
        w.groupTab(ids[1], onto: ids[0])                 // G1
        w.groupTab(ids[3], onto: ids[2])                 // G2
        let g1 = try #require(w.tabGroups[0].id)
        let g2 = try #require(w.tabGroups[1].id)
        w.moveGroup(g2, intoGroup: g1)                   // G2 nested in G1
        // Selecting both G1 and G2: G2 is a descendant → drop.
        let result = w.payloadAncestorFilter(tabIDs: [], groupIDs: [g1, g2])
        #expect(result.tabs.isEmpty)
        #expect(result.groups == [g1])
        _ = ids
    }
}
