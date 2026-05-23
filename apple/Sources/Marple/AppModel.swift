import Foundation
import MarpleKit
import Observation

@Observable @MainActor
final class AppModel {
    let client: VaultClient
    var entries: [Entry] = []
    var status: String = ""

    // Browse state
    var pane: Pane = .type(.paperAnalysis)
    var sortClauses: [SortClause] = []
    var filterClauses: [FilterClause] = []
    var filterMatch: FilterMatch = .all
    var searchText: String = ""
    var searchHits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?

    // Reading state
    var openPath: String?
    var openBlocks: [RenderBlock] = []

    init(client: VaultClient) { self.client = client }

    // MARK: derived

    var counts: [EntryType: Int] {
        var c: [EntryType: Int] = [:]
        for e in entries { c[e.type, default: 0] += 1 }
        return c
    }

    var themeIndex: [ThemeCount] { themeCounts(entries) }

    /// The middle-column list: search results when searching, else the
    /// pane subset run through filters then sort.
    var visibleEntries: [Entry] {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return searchHits.map(\.entry)
        }
        let base = entriesForPane(pane, in: entries)
        let filtered = applyFilters(base, filterClauses, match: filterMatch)
        return sortEntries(filtered, by: sortClauses)
    }

    // MARK: actions

    func loadIndex() async {
        do {
            entries = try await client.index()
            status = "\(entries.count) entries"
            print("[marple] index loaded: \(entries.count) entries")
        } catch {
            status = "index failed: \(error)"
            print("[marple] index FAILED: \(error)")
        }
    }

    func select(pane newPane: Pane) {
        pane = newPane
        searchText = ""; searchHits = []
        print("[marple] pane -> \(newPane)")
    }

    /// Debounced server search scoped to the current type pane (nil type → all).
    func runSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = []; return }
        let type: EntryType? = { if case .type(let t) = pane { return t } else { return nil } }()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let hits = try await self?.client.search(SearchQuery(q: q, type: type)) ?? []
                if Task.isCancelled { return }
                self?.searchHits = hits
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
