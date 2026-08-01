import Foundation

// Immediate index-derived recompute (entries 变即重算)：counts / themeIndex /
// topicMembership / savedViewCounts。Split out of Catalog.swift (QUA-218 PR3a
// Task 8); reads the Catalog-owned entries snapshot.
extension Catalog {
    /// entries 变更后的立即派生（counts/themeIndex/topicMembership/savedViewCounts），
    /// 末尾接上 deferred 派生（relationGraph/searchIndex）。
    /// 旧 AppModel.rebuildIndexDerived 立即段 + recomputeSavedViewCounts
    /// + scheduleDeferredDerivedRebuild。
    public func rebuildIndexDerived(savedViews: [SavedView]) {
        // The graph is built from a snapshot in the deferred task. Invalidate
        // the previous snapshot before refreshing open relations, otherwise a
        // vault change can keep showing the old relation lists until the task
        // publishes, including entries that no longer belong to the snapshot.
        relationGraph = .empty

        var c: [EntryType: Int] = [:]
        for e in entries { c[e.type, default: 0] += 1 }
        // QUA-189: the 专题 bucket folds to one row per topic (overview), so its
        // count must match the folded list, not the raw page total.
        if c[.topic] != nil { c[.topic] = topicBrowseSubset(entries).count }
        counts = c
        recomputeSavedViewCounts(savedViews: savedViews)
        themeIndex = themeCounts(entries)
        topicMembership = buildTopicMembership(entries)
        if hasOpenDerivedInput {
            recomputeOpenDerivedFromStoredInput()
        }
        scheduleDeferredDerivedRebuild(entries: entries)
    }

    /// Sidebar counts for saved views — each view's clauses over the browse
    /// universe, so count == list length (same contract as the topic bucket).
    /// Cheap: clause matching over the flat array, × a handful of views.
    public func recomputeSavedViewCounts(savedViews: [SavedView]) {
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
