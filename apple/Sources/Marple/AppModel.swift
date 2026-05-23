import Foundation
import MarpleKit
import Observation

@Observable @MainActor
final class AppModel {
    let client: VaultClient
    private(set) var entries: [Entry] = []
    var status: String = ""

    // Browse state (mutate via the intent methods below so derived caches refresh)
    private(set) var pane: Pane = .type(.paperAnalysis)
    private(set) var sortClauses: [SortClause] = []
    private(set) var filterClauses: [FilterClause] = []
    private(set) var filterMatch: FilterMatch = .all
    private(set) var searchText: String = ""
    private var searchHits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?

    // Derived caches — recomputed only when their inputs change, never in a view body.
    private(set) var counts: [EntryType: Int] = [:]
    private(set) var themeIndex: [ThemeCount] = []
    private(set) var visibleEntries: [Entry] = []

    // Reading state
    var openPath: String?
    var openBlocks: [RenderBlock] = []

    init(client: VaultClient) { self.client = client }

    // MARK: derived recompute

    /// Rebuild the index-wide caches (counts + theme index). O(n) over all entries;
    /// runs once per index load, not per render.
    private func rebuildIndexDerived() {
        var c: [EntryType: Int] = [:]
        for e in entries { c[e.type, default: 0] += 1 }
        counts = c
        themeIndex = themeCounts(entries)
    }

    /// Rebuild the middle-column list: search hits when searching, else the pane
    /// subset run through filters then sort. Call after any browse-state change.
    private func recomputeVisible() {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            visibleEntries = searchHits.map(\.entry)
            return
        }
        let base = entriesForPane(pane, in: entries)
        let filtered = applyFilters(base, filterClauses, match: filterMatch)
        visibleEntries = sortEntries(filtered, by: sortClauses)
    }

    // MARK: actions

    func loadIndex() async {
        do {
            entries = try await client.index()
            status = "\(entries.count) entries"
            rebuildIndexDerived()
            recomputeVisible()
            print("[marple] index loaded: \(entries.count) entries")
        } catch {
            status = "index failed: \(error)"
            print("[marple] index FAILED: \(error)")
        }
    }

    func select(pane newPane: Pane) {
        pane = newPane
        searchText = ""; searchHits = []
        recomputeVisible()
        print("[marple] pane -> \(newPane)")
    }

    func setSort(_ clauses: [SortClause]) {
        sortClauses = clauses
        recomputeVisible()
    }

    func setFilters(_ clauses: [FilterClause], match: FilterMatch = .all) {
        filterClauses = clauses
        filterMatch = match
        recomputeVisible()
    }

    func setSearchText(_ text: String) {
        searchText = text
        runSearch()
    }

    /// Debounced server search scoped to the current type pane (nil type → all).
    private func runSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = []; recomputeVisible(); return }
        let type: EntryType? = { if case .type(let t) = pane { return t } else { return nil } }()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let hits = try await self?.client.search(SearchQuery(q: q, type: type)) ?? []
                if Task.isCancelled { return }
                self?.searchHits = hits
                self?.recomputeVisible()
                print("[marple] search '\(q)' -> \(hits.count) hits")
            } catch {
                self?.status = "search failed: \(error)"
                print("[marple] search FAILED '\(q)': \(error)")
            }
        }
    }

    func open(_ path: String) async {
        openPath = path
        do {
            let raw = try await client.entryText(path: path)
            openBlocks = MarkdownModel.blocks(from: Frontmatter.split(raw).body)
            print("[marple] open \(path) -> \(openBlocks.count) blocks (\(raw.count) chars)")
        } catch {
            openBlocks = [.paragraph([.text("load failed: \(error)")])]
            print("[marple] open FAILED \(path): \(error)")
        }
    }

    func reloadOpen() async {
        if let p = openPath { print("[marple] watcher reload \(p)"); await open(p) }
    }

    func follow(_ target: String) async {
        if let hit = WikiResolver.resolve(target, in: entries) {
            print("[marple] follow [[\(target)]] -> \(hit.path)")
            await open(hit.path)
        } else {
            status = "unresolved [[\(target)]]"
            print("[marple] follow [[\(target)]] -> UNRESOLVED")
        }
    }

    func openExternally() async {
        guard let p = openPath else { return }
        do {
            try await client.openInEditor(path: p, app: "")
            print("[marple] openInEditor \(p)")
        } catch {
            status = "open-in-editor failed: \(error)"
            print("[marple] openInEditor FAILED \(p): \(error)")
        }
    }
}
