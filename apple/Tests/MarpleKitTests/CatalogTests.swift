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

        c.rebuildIndexDerived(entries: entries, savedViews: [])

        // Raw counts per type, except the topic bucket folds to one row per slug.
        #expect(c.counts[.paper] == 1)
        #expect(c.counts[.note] == 1)
        #expect(c.counts[.topic] == 1)   // two topic pages, one slug

        // Topic membership: the paper declares topics:[embodiment]; the overview
        // page wins the slug→entry mapping (path-first).
        #expect(Set(c.topicMembership.membersBySlug["embodiment"]?.map(\.path) ?? []) == Set(["vault/papers/p.md"]))
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

        c.recomputeSavedViewCounts(entries: entries, savedViews: [view])
        #expect(c.savedViewCounts[view.id] == 2)

        // Empty saved-view list clears the cache.
        c.recomputeSavedViewCounts(entries: entries, savedViews: [])
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
}
