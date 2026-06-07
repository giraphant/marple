import Testing
@testable import MarpleKit

// MARK: - TopicContext tests (QUA-189)
//
// Topic counterpart to BookContextTests. Pins the overview-anchor + ordered
// sub-page gathering that drives the inspector's "本专题" navigation. The key
// difference from book/chapter: every page is `type=topic`, split by `kind`.

@Suite struct TopicContextTests {

    func mk(_ path: String, kind: String? = nil, title: String? = nil) -> Entry {
        Entry(path: path, type: .topic, title: title, author: [],
              year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false,
              kind: kind)
    }

    @Test func gathersOverviewAndPagesFromAResourcesPage() {
        let ov = mk("vault/topics/repair/00-overview.md", kind: "overview", title: "Repair")
        let r2 = mk("vault/topics/repair/02-resources.md", kind: "resources", title: "More")
        let r1 = mk("vault/topics/repair/01-resources.md", kind: "resources", title: "Reading")
        let other = mk("vault/topics/other/00-overview.md", kind: "overview")

        let ctx = topicContext(for: r1, in: [ov, r2, r1, other])
        #expect(ctx?.slug == "repair")
        #expect(ctx?.overview?.path == ov.path)
        #expect(ctx?.pages.map(\.path) == [
            "vault/topics/repair/01-resources.md",
            "vault/topics/repair/02-resources.md",
        ])  // path-sorted, overview excluded
    }

    @Test func overviewPickedByKindNotPathOrder() {
        // A non-overview page sorts first by path; the kind tag must still win.
        let res = mk("vault/topics/repair/00-resources.md", kind: "resources")
        let ov = mk("vault/topics/repair/01-overview.md", kind: "overview")
        let ctx = topicContext(for: ov, in: [res, ov])
        #expect(ctx?.overview?.path == ov.path)
        #expect(ctx?.pages.map(\.path) == ["vault/topics/repair/00-resources.md"])
    }

    @Test func singlePageTopicReturnsNil() {
        // Overview only → a "本专题" panel would list just the open page → no panel.
        let ov = mk("vault/topics/solo/00-overview.md", kind: "overview")
        #expect(topicContext(for: ov, in: [ov]) == nil)
    }

    @Test func nilForNonTopicEntry() {
        let p = Entry(path: "vault/papers/p.md", type: .paper, title: nil, author: [],
                      year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        #expect(topicContext(for: p, in: [p]) == nil)
    }

    @Test func fallsBackToPathFirstWhenNoOverviewKind() {
        // No page tagged kind=overview → the path-first page is the anchor.
        let a = mk("vault/topics/x/01-a.md", kind: "resources")
        let b = mk("vault/topics/x/02-b.md", kind: "resources")
        let ctx = topicContext(for: b, in: [b, a])
        #expect(ctx?.overview?.path == "vault/topics/x/01-a.md")
        #expect(ctx?.pages.map(\.path) == ["vault/topics/x/02-b.md"])
    }

    @Test func doesNotMixOtherTopics() {
        let aOv = mk("vault/topics/a/00-overview.md", kind: "overview")
        let aRes = mk("vault/topics/a/01-resources.md", kind: "resources")
        let bRes = mk("vault/topics/b/01-resources.md", kind: "resources")
        let ctx = topicContext(for: aRes, in: [aOv, aRes, bRes])
        #expect(ctx?.overview?.path == aOv.path)
        #expect(ctx?.pages.map(\.path) == ["vault/topics/a/01-resources.md"])
    }
}
