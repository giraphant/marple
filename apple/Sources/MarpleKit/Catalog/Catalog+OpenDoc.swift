import Foundation

// Open-doc derived caches：recomputeOpenDerived（openEntry/openOutline/openStats/
// openRelations/openBook/openTopic）。Split out of Catalog.swift (QUA-218 PR3a Task 8);
// method body is byte-identical to the original.
extension Catalog {
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
