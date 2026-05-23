import Testing
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

    @Test func testMoveReorders() {
        var w = Workspace(initial: a)
        w.newTab(b); w.newTab(c)    // [a, b, c]
        let cID = w.tabs[2].id
        let aID = w.tabs[0].id
        w.move(id: cID, before: aID) // -> [c, a, b]
        #expect(w.tabs.map(\.location) == [c, a, b])
    }

    @Test func testMoveOntoSelfIsNoOp() {
        var w = Workspace(initial: a)
        w.newTab(b)                 // [a, b]
        let aID = w.tabs[0].id
        w.move(id: aID, before: aID)
        #expect(w.tabs.map(\.location) == [a, b])
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
}
