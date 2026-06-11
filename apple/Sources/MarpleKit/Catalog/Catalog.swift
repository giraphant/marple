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

    public init() {}

    /// Seed the restored last-session counts before the first `loadIndex` publishes
    /// live ones, so the sidebar shows cached badges during the bootstrap window
    /// (QUA-105). Once `rebuildIndexDerived` runs, `counts` is authoritative.
    public func seedCounts(_ restored: [EntryType: Int]) { counts = restored }

    /// entries 变更后的立即派生（counts/themeIndex/topicMembership/savedViewCounts）。
    /// 逐字 = 旧 AppModel.rebuildIndexDerived 立即段 + recomputeSavedViewCounts。
    /// deferred 段（relationGraph/searchIndex）仍由 AppModel 触发（Task 3 迁入）。
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
