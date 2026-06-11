import Foundation

/// L2 编目层的派生状态 owner（QUA-218 PR3a）。图书馆目录隐喻：从馆藏（vault）
/// 派生、可随时重编、多路检索、带交叉引用。本期持有派生缓存 + vault-变更管线
/// 的统一 generation/单飞权威；entries 与 index 管线过渡期仍在 AppModel。
@MainActor
@Observable
public final class Catalog {
    // TODO(QUA-218 PR3a Task 5): when open-doc derived lands, consider splitting
    // Catalog into extension files by concern (index-derived / visible+search / open-doc).
    // 索引派生（entries 变即重算）
    public internal(set) var counts: [EntryType: Int] = [:]
    public internal(set) var savedViewCounts: [UUID: Int] = [:]
    public internal(set) var topicMembership: TopicMembership = TopicMembership()
    public internal(set) var themeIndex: [ThemeCount] = []

    // deferred 派生（entries 变更后台重算）
    public internal(set) var relationGraph: RelationGraph = .empty
    public internal(set) var searchIndex: SearchIndex = .empty
    /// 派生就绪回调（过渡期）：deferred 派生发布后,若有开档则重算开档派生。
    /// Task 5 把 recomputeOpenDerived 迁入后改为内部直调。
    public var onDerivedReady: (() -> Void)?
    private var deferredDerivedTask: Task<Void, Never>?
    private var derivedGeneration: Int = 0

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
    private var recomputeTask: Task<Void, Never>?
    /// 搜索匹配加载防抖轴（独立，不并入统一 generation）
    private var matchTask: Task<Void, Never>?

    public init() {}

    /// Bootstrap-only: seed counts from persisted state in AppModel.init BEFORE
    /// the first rebuildIndexDerived. Calling it afterwards overwrites live counts
    /// with stale restored data. Not a general setter.
    public func seedCounts(_ restored: [EntryType: Int]) { counts = restored }

    /// entries 变更后的立即派生（counts/themeIndex/topicMembership/savedViewCounts），
    /// 末尾接上 deferred 派生（relationGraph/searchIndex）。
    /// 逐字 = 旧 AppModel.rebuildIndexDerived 立即段 + recomputeSavedViewCounts
    /// + scheduleDeferredDerivedRebuild。
    public func rebuildIndexDerived(entries: [Entry], savedViews: [SavedView]) {
        var c: [EntryType: Int] = [:]
        for e in entries { c[e.type, default: 0] += 1 }
        // QUA-189: the 专题 bucket folds to one row per topic (overview), so its
        // count must match the folded list, not the raw page total.
        if c[.topic] != nil { c[.topic] = topicBrowseSubset(entries).count }
        counts = c
        recomputeSavedViewCounts(entries: entries, savedViews: savedViews)
        themeIndex = themeCounts(entries)
        topicMembership = buildTopicMembership(entries)
        scheduleDeferredDerivedRebuild(entries: entries)
    }

    /// Build the heavy derived caches (relation graph, search index) on a
    /// background task and publish them on the main actor when done. If
    /// `entries` changes again before this task completes, the in-flight task
    /// is cancelled and stale dispatch blocks are vetoed by generation counter
    /// — only the latest snapshot wins.
    private func scheduleDeferredDerivedRebuild(entries: [Entry]) {
        deferredDerivedTask?.cancel()
        derivedGeneration &+= 1
        let generation = derivedGeneration
        let snapshot = entries
        deferredDerivedTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let graph = RelationGraph.build(snapshot)
                let search = buildSearchIndex(snapshot)
                return (graph, search)
            }.value
            if Task.isCancelled { return }
            // Hop to the next main-runloop tick (not MainActor.run, which can
            // run synchronously inside the current render pass and triggered an
            // NSTableView reentrant-delegate warning when @Observable
            // invalidation cascaded back into the table mid-render).
            //
            // DispatchQueue.main.async can't be cancelled, so guard the
            // assignment with the generation counter: any newer rebuild bumps
            // `derivedGeneration` and this stale block becomes a no-op.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.derivedGeneration == generation else { return }
                self.relationGraph = result.0
                self.searchIndex = result.1
                self.onDerivedReady?()
            }
        }
    }

    /// Sidebar counts for saved views — each view's clauses over the browse
    /// universe, so count == list length (same contract as the topic bucket).
    /// Cheap: clause matching over the flat array, × a handful of views.
    public func recomputeSavedViewCounts(entries: [Entry], savedViews: [SavedView]) {
        guard !savedViews.isEmpty else {
            if !savedViewCounts.isEmpty { savedViewCounts = [:] }
            return
        }
        let universe = browseUniverse(entries)
        var result: [UUID: Int] = [:]
        for view in savedViews {
            result[view.id] = applyFilters(universe, view.clauses, match: view.match).count
        }
        savedViewCounts = result
    }

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

    // 开档派生缓存（open / reload / metadata 写时重算，非每帧）（QUA-218 PR3a Task 5）
    public internal(set) var openEntry: Entry?
    public internal(set) var openOutline: [OutlineItem] = []
    public internal(set) var openStats: DocStats?
    public internal(set) var openRelations: Relations?
    public internal(set) var openBook: BookContext?
    public internal(set) var openTopic: TopicContext?

    /// Recompute the open document's outline / stats / entry / relations. O(n) over
    /// the index for relations; runs on open / reload / metadata write, not per render.
    ///
    /// 逐字 = 旧 AppModel.recomputeOpenDerived。openPath/openBody 由壳传入（loadDoc
    /// 设的文本/导航态）；relationGraph/topicMembership 用 self 的（已在 Catalog）。
    /// renderSize/renderLineHeight 是壳的 ReadingDefaults 常量（Marple 模块不可见于
    /// MarpleKit），由壳传入以保持渲染调用逐字不变。
    public func recomputeOpenDerived(openPath: String?, openBody: String, entries: [Entry],
                                     renderSize: Double, renderLineHeight: Double) {
        openEntry = entries.first { $0.path == openPath }
        let preprocessed = Wikilink.preprocessForRendering(openBody)
        let rendered = MarkdownRenderer.render(preprocessed, style: RenderStyle(
            size: renderSize, fontFamily: nil, lineHeight: renderLineHeight
        ))
        openOutline = outline(from: rendered.headings)
        openStats = openBody.isEmpty ? nil : computeDocStats(openBody)
        if let e = openEntry {
            openRelations = relations(for: e, in: entries,
                                      graph: relationGraph,
                                      topicMembership: topicMembership)
            openBook = bookContext(for: e, in: entries)
            openTopic = topicContext(for: e, in: entries)
        } else {
            openRelations = nil
            openBook = nil
            openTopic = nil
        }
    }
}
