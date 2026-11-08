import Foundation

/// One window's view onto the shared `Catalog`: its visible browse list, list-search
/// match excerpts, and the open document's derived caches. Every window owns one;
/// the index-wide snapshot, caches and refresh authority stay in the single shared
/// `Catalog`, which tells each live viewport when index-wide caches it reads change.
@MainActor
@Observable
public final class CatalogViewport {
    public let catalog: Catalog

    // 可见列表 + 列表搜索匹配缓存（QUA-218 PR3a Task 4）
    public internal(set) var visibleEntries: [Entry] = []
    /// Per-result matched body lines for the current list search (keyed by path).
    /// Populated off-main after the search settles; rows read from it.
    public internal(set) var searchMatches: [String: BodyMatches] = [:]
    /// The query `searchMatches` was computed for. A matched-line tap uses THIS
    /// (not the live `searchText`) so a tap during the debounce window stays
    /// self-consistent — anchor/ordinal/query always describe the same search.
    public internal(set) var searchMatchQuery: String = ""
    /// Result rows whose "再显示 N 个匹配项" expander has been opened.
    public var matchExpanded: Set<String> = []
    /// filter/sort 防抖轴（独立，不并入统一 generation）
    @ObservationIgnored var recomputeTask: Task<Void, Never>?
    /// 搜索匹配加载防抖轴（独立，不并入统一 generation）
    @ObservationIgnored var matchTask: Task<Void, Never>?

    // 开档派生缓存（open / reload / metadata 写时重算，非每帧）（QUA-218 PR3a Task 5）
    public internal(set) var openEntry: Entry?
    public internal(set) var openOutline: [OutlineItem] = []
    public internal(set) var openStats: DocStats?
    public internal(set) var openRelations: Relations?
    public internal(set) var openBook: BookContext?
    public internal(set) var openTopic: TopicContext?
    /// Last shell-supplied open-doc inputs, kept so index-wide rebuilds in the
    /// shared Catalog can refresh the derived outputs without a shell callback.
    @ObservationIgnored var openDerivedPath: String?
    @ObservationIgnored var openDerivedBody: String = ""
    @ObservationIgnored var openDerivedBlocks: [RenderBlock] = []

    public init(catalog: Catalog) {
        self.catalog = catalog
        catalog.register(self)
    }

    /// Stop this window's background list work (window closing).
    public func cancel() {
        recomputeTask?.cancel()
        matchTask?.cancel()
    }

    // MARK: visible list + list-search matches

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
                if Task.isCancelled { return }
                // This Task inherits MainActor; keep the CPU work on a snapshot
                // off that actor, with at most one document in flight per query.
                let m = await Task.detached(priority: .userInitiated) {
                    bodyLineMatches(body: Frontmatter.split(raw).body, query: query)
                }.value
                if Task.isCancelled { return }
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

    /// Confirmed filesystem moves: re-point this window's rows and match caches.
    func remapArchivePaths(_ moves: [ArchiveCollectionChange]) {
        recomputeTask?.cancel()
        matchTask?.cancel()
        func path(_ value: String) -> String { ArchiveCollectionReferences.remap(value, moves: moves) }
        visibleEntries = visibleEntries.map { entry in
            let next = path(entry.path)
            return next == entry.path ? entry : entry.with(path: next)
        }
        searchMatches = Dictionary(searchMatches.map { (path($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        matchExpanded = Set(matchExpanded.map(path))
    }

    // MARK: open document

    /// Recompute the open document's outline / stats / entry / relations. O(n) over
    /// the index for relations; runs on open / reload / metadata write, not per render.
    ///
    /// openPath/openBody/openBlocks 由壳传入（loadDoc 设的文本/导航态/解析块）；
    /// relationGraph/topicMembership 用共享 Catalog 的。
    ///
    /// 大纲走无字体路径：openBlocks 是 MarkdownModel.blocks 的纯解析结果，标题的
    /// level/text 与字体无关，故编目层不再关心渲染样式（QUA-227）。代价：OutlineItem
    /// 无 characterRange，Inspector 点击滚动的偏移改由 live MarkdownTextView 按序号提供。
    public func recomputeOpenDerived(openPath: String?, openBody: String,
                                     openBlocks: [RenderBlock]) {
        openDerivedPath = openPath
        openDerivedBody = openBody
        openDerivedBlocks = openBlocks
        recomputeOpenDerivedFromStoredInput()
    }

    var hasOpenDerivedInput: Bool {
        openDerivedPath != nil || !openDerivedBody.isEmpty || !openDerivedBlocks.isEmpty
    }

    func recomputeOpenDerivedFromStoredInput() {
        let openPath = openDerivedPath
        let openBody = openDerivedBody
        let openBlocks = openDerivedBlocks
        let entries = catalog.entries
        openEntry = catalog.entry(at: openPath)
        openOutline = outline(from: openBlocks)
        openStats = openBody.isEmpty ? nil : computeDocStats(openBody)
        if let e = openEntry {
            openRelations = relations(for: e, in: entries,
                                      graph: catalog.relationGraph,
                                      topicMembership: catalog.topicMembership)
            openBook = bookContext(for: e, in: entries)
            openTopic = topicContext(for: e, in: entries)
        } else {
            openRelations = nil
            openBook = nil
            openTopic = nil
        }
    }

    /// Index-wide caches the open document reads changed (called by the Catalog).
    func refreshOpenDerived() {
        if hasOpenDerivedInput { recomputeOpenDerivedFromStoredInput() }
    }
}
