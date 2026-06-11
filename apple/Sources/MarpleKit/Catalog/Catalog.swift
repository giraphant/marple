import Foundation

/// L2 编目层的派生状态 owner（QUA-218 PR3a）。图书馆目录隐喻：从馆藏（vault）
/// 派生、可随时重编、多路检索、带交叉引用。本期持有派生缓存 + vault-变更管线
/// 的统一 generation/单飞权威；entries 与 index 管线过渡期仍在 AppModel。
@MainActor
@Observable
public final class Catalog {
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
}
