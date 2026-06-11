import Foundation

// Visible list + list-search match caches：recomputeVisible / computeSearchMatches /
// clearSearchMatches / toggleMatchExpanded（独立防抖轴 recomputeTask/matchTask）。
// Split out of Catalog.swift (QUA-218 PR3a Task 8); method bodies are byte-identical
// to the original.
extension Catalog {
    /// The visible browse subset (filter→sort over ~15k entries) is computed OFF the
    /// main thread and applied back on main, with stale rebuilds dropped via task
    /// cancellation. This keeps clearing search / switching panes off the keystroke so
    /// text input never blocks — mirrors NetNewsWire/FSNotes/CodeEdit list-search
    /// discipline (don't re-filter synchronously in the input handler).
    ///
    /// Inputs are snapshotted at entry by the shell (searchText/searchHits/pane/
    /// filters/match/sorts/entries): the search-active branch and the off-main
    /// filter/sort both read state captured when `recomputeVisible` was called.
    public func recomputeVisible(searchText: String, searchHits: [SearchHit],
                                 pane: Pane, entries: [Entry],
                                 filters: [FilterClause], match: FilterMatch,
                                 sorts: [SortClause]) {
        recomputeTask?.cancel()
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            visibleEntries = searchHits.map(\.entry)
            return
        }
        let snapshot = entries
        recomputeTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                sortEntries(applyFilters(entriesForPane(pane, in: snapshot), filters, match: match),
                            by: sorts)
            }.value
            guard !Task.isCancelled else { return }
            self?.visibleEntries = result
        }
    }

    public func clearSearchMatches() {
        matchTask?.cancel()
        searchMatches = [:]
        searchMatchQuery = ""
        matchExpanded = []
    }

    /// Load each result's stripped body off-main and compute its matched lines.
    /// Bounded to the hit set (≤ search limit); cancellable and query-versioned so a
    /// stale load can never attach excerpts to a newer query's rows. Matches the
    /// stripped body (not the raw file) so frontmatter can't create phantom matches.
    ///
    /// `query`/`paths`/`client` are snapshots taken at call entry. `currentSearchText`
    /// is a LIVE closure: the publish guard re-reads the shell's CURRENT searchText at
    /// the async publish point (post-await), so a tap during the debounce window stays
    /// self-consistent — a snapshot here would let a stale query attach to newer rows.
    public func computeSearchMatches(query: String, paths: [String],
                                     client: VaultClient,
                                     currentSearchText: @escaping () -> String) {
        matchTask?.cancel()
        matchExpanded = []
        searchMatches = [:]
        matchTask = Task { [weak self] in
            var result: [String: BodyMatches] = [:]
            for path in paths {
                if Task.isCancelled { return }
                guard let raw = try? await client.entryText(path: path) else { continue }
                let body = Frontmatter.split(raw).body
                let m = bodyLineMatches(body: body, query: query)
                if !m.lines.isEmpty { result[path] = m }
            }
            if Task.isCancelled { return }
            guard let self,
                  currentSearchText().trimmingCharacters(in: .whitespaces) == query else { return }
            self.searchMatches = result
            self.searchMatchQuery = query
        }
    }

    /// Toggle a result row's "再显示 N 个匹配项" expander.
    public func toggleMatchExpanded(_ path: String) {
        if matchExpanded.contains(path) { matchExpanded.remove(path) }
        else { matchExpanded.insert(path) }
    }
}
