import Foundation

// Open-doc derived caches：recomputeOpenDerived（openEntry/openOutline/openStats/
// openRelations/openBook/openTopic）。Split out of Catalog.swift (QUA-218 PR3a Task 8);
// method body is byte-identical to the original.
extension Catalog {
    /// Recompute the open document's outline / stats / entry / relations. O(n) over
    /// the index for relations; runs on open / reload / metadata write, not per render.
    ///
    /// openPath/openBody/openBlocks 由壳传入（loadDoc 设的文本/导航态/解析块）；
    /// relationGraph/topicMembership 用 self 的（已在 Catalog）。
    ///
    /// 大纲走无字体路径：openBlocks 是 MarkdownModel.blocks 的纯解析结果，标题的
    /// level/text 与字体无关，故编目层不再关心渲染样式（QUA-227）。代价：OutlineItem
    /// 无 characterRange，Inspector 点击滚动的偏移改由 live MarkdownTextView 按序号提供。
    public func recomputeOpenDerived(openPath: String?, openBody: String,
                                     openBlocks: [RenderBlock], entries: [Entry]) {
        openEntry = entries.first { $0.path == openPath }
        openOutline = outline(from: openBlocks)
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
