import Testing
@testable import MarpleKit

@MainActor @Suite struct CatalogTests {
    /// Test factory for Entry, with an `annotates:` knob for relation cases.
    func mk(_ path: String, _ type: String, title: String? = nil, author: String? = nil,
            themes: [String] = [], topics: [String] = [], rating: Double = 0, book: String? = nil,
            annotates: String? = nil) -> Entry {
        Entry(path: path, type: EntryType(rawValue: type), title: title,
              author: splitAuthors(author),
              year: nil, ratingScore: rating, themes: themes, topics: topics,
              preview: "", hasPDF: false,
              book: book, annotates: annotates)
    }

    @Test func themeIndexStoresAndReads() {
        let c = Catalog()
        c.themeIndex = [ThemeCount(theme: "存在主义", count: 3)]
        #expect(c.themeIndex.count == 1)
        #expect(c.themeIndex.first?.theme == "存在主义")
    }

    @Test func rebuildIndexDerivedCountsAndTopicMembership() {
        let c = Catalog()
        let paper = mk("vault/papers/p.md", "paper", topics: ["embodiment"])
        let note = mk("vault/notes/n.md", "note")
        // Two topic pages under the same slug fold to ONE row in the topic bucket.
        let overview = mk("vault/topics/embodiment/00-overview.md", "topic")
        let resources = mk("vault/topics/embodiment/01-resources.md", "topic")
        let entries = [paper, note, overview, resources]
        c.entries = entries

        c.rebuildIndexDerived(savedViews: [])

        // Raw counts per type, except the topic bucket folds to one row per slug.
        #expect(c.counts[.paper] == 1)
        #expect(c.counts[.note] == 1)
        #expect(c.counts[.topic] == 1)   // two topic pages, one slug

        // Topic forward index: the overview page wins the slug→entry mapping
        // (path-first). Reverse membership now lives in the relation graph (inTopic).
        #expect(c.topicMembership.topicEntryBySlug["embodiment"]?.path == "vault/topics/embodiment/00-overview.md")
    }

    @Test func recomputeSavedViewCountsMatchesClauses() {
        let c = Catalog()
        let p1 = mk("vault/papers/a.md", "paper", rating: 5)
        let p2 = mk("vault/papers/b.md", "paper", rating: 2)
        let note = mk("vault/notes/n.md", "note", rating: 5)
        let entries = [p1, p2, note]
        let view = SavedView(name: "papers",
                             clauses: [FilterClause(field: .type, op: .is_, value: "paper")],
                             match: .all, sorts: [])
        c.entries = entries

        c.recomputeSavedViewCounts(savedViews: [view])
        #expect(c.savedViewCounts[view.id] == 2)

        // Empty saved-view list clears the cache.
        c.recomputeSavedViewCounts(savedViews: [])
        #expect(c.savedViewCounts.isEmpty)
    }

    @Test func recomputeVisibleSearchActiveUsesHits() {
        let c = Catalog()
        let hit = SearchHit(entry: mk("vault/papers/a.md", "paper"), score: 1,
                            snippet: nil, source: "test")
        // Non-empty searchText → search-active branch: visibleEntries = the hits,
        // synchronously (no off-main task).
        c.recomputeVisible(searchText: "embodiment", searchHits: [hit], pane: .type(.paper),
                           entries: [], filters: [], match: .all, sorts: [])
        #expect(c.visibleEntries.map(\.path) == ["vault/papers/a.md"])
    }

    @Test func recomputeVisibleBrowseFiltersAndSorts() async {
        let c = Catalog()
        let p1 = mk("vault/papers/a.md", "paper")
        let p2 = mk("vault/papers/b.md", "paper")
        let note = mk("vault/notes/n.md", "note")
        // Empty searchText → browse branch: pane .type(.paper) keeps only papers,
        // off-main, applied on main.
        c.recomputeVisible(searchText: "", searchHits: [], pane: .type(.paper),
                           entries: [p1, p2, note],
                           filters: [], match: .all, sorts: [])
        // Let the off-main task settle.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(Set(c.visibleEntries.map(\.path)) == Set(["vault/papers/a.md", "vault/papers/b.md"]))
    }

    @Test func toggleAndClearSearchMatches() {
        let c = Catalog()
        c.toggleMatchExpanded("vault/papers/a.md")
        #expect(c.matchExpanded.contains("vault/papers/a.md"))
        c.toggleMatchExpanded("vault/papers/a.md")
        #expect(!c.matchExpanded.contains("vault/papers/a.md"))

        c.matchExpanded = ["x"]
        c.clearSearchMatches()
        #expect(c.searchMatches.isEmpty)
        #expect(c.searchMatchQuery.isEmpty)
        #expect(c.matchExpanded.isEmpty)
    }

    // MARK: - open-doc derive (QUA-218 PR3a Task 5)

    /// Opening a chapter surfaces its book context (overview + ordered chapters).
    @Test func openDerivedChapterBuildsBookContext() {
        let c = Catalog()
        let overview = mk("vault/books/being-time/00-overview.md", "book")
        let ch1 = mk("vault/books/being-time/01-intro.md", "chapter", book: "being-time")
        let ch2 = mk("vault/books/being-time/02-care.md", "chapter", book: "being-time")
        let entries = [overview, ch1, ch2]
        c.entries = entries

        c.recomputeOpenDerived(openPath: ch1.path, openBody: "# Intro\n\nbody",
                               openBlocks: MarkdownModel.blocks(from: "# Intro\n\nbody"))

        #expect(c.openEntry?.path == ch1.path)
        #expect(c.openBook?.slug == "being-time")
        #expect(c.openBook?.overview?.path == overview.path)
        #expect(c.openBook?.chapters.map(\.path) == [ch1.path, ch2.path])
        #expect(c.openStats != nil)                    // non-empty body → stats
        #expect(c.openTopic == nil)                    // not a topic page
    }

    /// Opening a topic overview surfaces its topic context (sibling pages).
    @Test func openDerivedTopicBuildsTopicContext() {
        let c = Catalog()
        let overview = mk("vault/topics/embodiment/00-overview.md", "topic")
        let resources = mk("vault/topics/embodiment/01-resources.md", "topic")
        let entries = [overview, resources]
        c.entries = entries

        c.recomputeOpenDerived(openPath: overview.path, openBody: "# 本专题",
                               openBlocks: MarkdownModel.blocks(from: "# 本专题"))

        #expect(c.openEntry?.path == overview.path)
        #expect(c.openTopic?.slug == "embodiment")
        #expect(c.openTopic?.overview?.path == overview.path)
        #expect(c.openTopic?.pages.map(\.path) == [resources.path])
        #expect(c.openBook == nil)                     // not a book/chapter
    }

    /// Opening an author page surfaces their works via catalog.relationGraph.
    @Test func openDerivedAuthorWorksViaRelationGraph() {
        let c = Catalog()
        let author = mk("vault/authors/pb.md", "author", title: "Pierre Bourdieu")
        let p1 = mk("vault/papers/distinction.md", "paper", author: "Pierre Bourdieu", rating: 5)
        let p2 = mk("vault/papers/habitus.md", "paper", author: "Pierre Bourdieu", rating: 3)
        let entries = [author, p1, p2]
        c.entries = entries
        // Seed the catalog's relation graph (works→author edges) so relations()
        // reads it rather than the empty-graph fallback.
        c.relationGraph = RelationGraph.build(entries)

        c.recomputeOpenDerived(openPath: author.path, openBody: "# Pierre Bourdieu",
                               openBlocks: MarkdownModel.blocks(from: "# Pierre Bourdieu"))

        #expect(c.openEntry?.path == author.path)
        // works ordered by rating desc.
        #expect(c.openRelations?.works.map(\.path) == [p1.path, p2.path])
    }

    /// Deferred relation-graph publication refreshes the stored open-doc inputs
    /// inside Catalog; no shell callback is needed for annotation-backed relations.
    @Test func deferredDerivedRefreshesStoredOpenDocRelations() async {
        let c = Catalog()
        let book = mk("vault/books/being-time/00-overview.md", "book", title: "Being and Time")
        let note = mk("vault/notes/annotation.md", "note", rating: 5, annotates: book.path)
        let entries = [book, note]
        c.entries = entries

        c.recomputeOpenDerived(openPath: book.path, openBody: "# Being and Time",
                               openBlocks: MarkdownModel.blocks(from: "# Being and Time"))
        #expect(c.openRelations?.annotations.isEmpty == true)

        c.rebuildIndexDerived(savedViews: [])

        for _ in 0..<20 {
            if c.openRelations?.annotations.map(\.path) == [note.path] { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(c.openRelations?.annotations.map(\.path) == [note.path])
    }

    /// No open path → entry/relations/book/topic clear; outline/stats reflect body.
    @Test func openDerivedNoOpenClears() {
        let c = Catalog()
        let entries = [mk("vault/papers/a.md", "paper")]
        c.entries = entries
        c.recomputeOpenDerived(openPath: nil, openBody: "",
                               openBlocks: MarkdownModel.blocks(from: ""))
        #expect(c.openEntry == nil)
        #expect(c.openRelations == nil)
        #expect(c.openBook == nil)
        #expect(c.openTopic == nil)
        #expect(c.openStats == nil)        // empty body
        #expect(c.openOutline.isEmpty)
    }

    // MARK: - 统一刷新权威 (QUA-218 PR3a Task 7) — 2→1 单飞 + per-pass generation

    /// pass bumps exactly once per body run; an old captured pass goes stale once
    /// a newer pass begins (旧 loadIndexGeneration staleness, now unified).
    @Test func refreshBumpsPassOncePerBodyAndStales() async {
        let c = Catalog()
        #expect(c.pass == 0)
        var seen: [Int] = []
        await c.refresh { myPass in seen.append(myPass) }
        #expect(c.pass == 1)
        #expect(seen == [1])             // one body run, one bump
        #expect(c.isStale(1) == false)   // current pass not stale

        await c.refresh { myPass in seen.append(myPass) }
        #expect(c.pass == 2)
        #expect(c.isStale(1) == true)    // an older pass is now stale
        #expect(c.isStale(2) == false)
    }

    /// A body that captures its pass, then a newer refresh bumps pass mid-body —
    /// the captured pass is stale, so the old body would drop its publish.
    @Test func capturedPassGoesStaleWhenNewerRefreshOvertakes() async {
        let c = Catalog()
        await c.refresh { _ in }          // pass = 1
        let captured = c.pass             // 1
        await c.refresh { _ in }          // pass = 2
        #expect(c.isStale(captured) == true)
    }

    /// OOM-safety proxy: M concurrent `catalog.refresh` calls collapse to ≤2 body
    /// runs (1 main + at most 1 trailing rerun), never M stacked chains. This is
    /// the unified-authority restatement of RefreshAuthority's coalescing bound.
    @Test func concurrentRefreshRunsBodyAtMostTwice() async {
        let c = Catalog()
        let counter = CatalogRefreshCounter()
        let release = CatalogRefreshGate()
        let M = 25

        // First refresh: admitted runner that parks inside its body, holding the
        // single flight open so the remaining M-1 calls arrive WHILE it's held.
        let first = Task { @MainActor in
            await c.refresh { _ in
                await counter.bump()
                await release.wait()
            }
        }
        // Let the first runner acquire + enter its body before the rest fire.
        try? await Task.sleep(nanoseconds: 20_000_000)

        var rest: [Task<Void, Never>] = []
        for _ in 0..<(M - 1) {
            rest.append(Task { @MainActor in
                await c.refresh { _ in await counter.bump() }
            })
        }
        // Give them a beat to coalesce into the single rerun flag, then release.
        try? await Task.sleep(nanoseconds: 20_000_000)
        await release.open()

        await first.value
        for t in rest { await t.value }

        let n = await counter.value
        #expect(n >= 1 && n <= 2)         // does NOT grow with M
    }

    /// CLI join path (refreshJoining): on an idle authority it acquires and runs a
    /// fresh pass — matching the old cliRefreshIndex `if beginOrJoin() { ... }`.
    @Test func refreshJoiningRunsFreshPassWhenIdle() async {
        let c = Catalog()
        var ran = 0
        await c.refreshJoining { _ in ran += 1 }
        #expect(ran == 1)
        #expect(c.pass == 1)
    }
}

/// Counts body executions across concurrent refresh calls (OOM proxy).
actor CatalogRefreshCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// One-shot gate: the first admitted refresh body parks on `wait()` until the
/// test `open()`s it, holding the single flight so concurrent calls coalesce.
actor CatalogRefreshGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        opened = true
        for w in waiters { w.resume() }
        waiters = []
    }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
