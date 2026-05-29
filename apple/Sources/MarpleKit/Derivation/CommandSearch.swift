import Foundation

/// The three search modes, mirroring the web reader's `searchMode.ts`
/// (and `reader_core::SearchMode`). 快速 = in-memory metadata ranker;
/// 平衡 = native FTS full-text; 深度 = semantic vectors (wired once the
/// vector index is built).
public enum SearchMode: String, CaseIterable, Sendable {
    case fast, balanced, deep

    /// Short segment label.
    public var label: String {
        switch self {
        case .fast: return "快速"
        case .balanced: return "平衡"
        case .deep: return "深度"
        }
    }

    /// Search-field placeholder.
    public var placeholder: String {
        switch self {
        case .fast: return "快速检索 标题/作者/标签…  Tab 切换 · ⏎ 打开 · Esc 关闭"
        case .balanced: return "平衡检索 标题/作者/标签/正文…  Tab 切换 · ⏎ 打开 · Esc 关闭"
        case .deep: return "深度检索 跨语言 / 概念 / 自然语言…  Tab 切换 · ⏎ 打开 · Esc 关闭"
        }
    }

    /// In-flight status text.
    public var loading: String {
        switch self {
        case .fast: return "元数据…"
        case .balanced: return "全文…"
        case .deep: return "深度…（向量索引）"
        }
    }

    public var paletteInlineScoreFloorRatio: Double? {
        switch self {
        case .fast: return nil
        case .balanced, .deep: return 0.60
        }
    }

    /// Next mode in the Tab cycle (wraps deep → fast).
    public func next() -> SearchMode {
        let all = SearchMode.allCases
        let i = all.firstIndex(of: self)!
        return all[(i + 1) % all.count]
    }
}

/// A subtle relevance-source tag for a result row. Only the semantically
/// distinctive sources (vector recall / vector+lexical fusion) get a badge —
/// plain lexical matches return nil so 快速/平衡 rows stay clean and 深度
/// visibly reveals what vectors added. Mirrors `searchMode.ts` `sourceBadge`.
public func searchSourceBadge(_ source: String?) -> String? {
    guard let source, let head = source.split(separator: " ").first else { return nil }
    switch head {
    case "hybrid": return "混合"
    case "vec": return "向量"
    default: return nil
    }
}

/// One per-type result group in the command palette.
public struct PaletteSection: Sendable, Identifiable, Equatable {
    public let type: EntryType
    public let total: Int
    public let top: [Entry]
    public var id: String { type.rawValue }
}

/// Bucket scored rows by type, sort within each bucket by score desc, take the
/// top `perType`, and emit sections in `order` — with `promote` (the list the
/// palette was opened from) pulled to the front. Empty buckets and types absent
/// from `order` are dropped. Faithful port of `CommandPalette.tsx`'s `sections`.
public func paletteSections(
    _ rows: [(entry: Entry, score: Double)],
    order: [EntryType],
    promote: EntryType?,
    perType: Int,
    minimumInlineScoreRatio: Double? = nil
) -> [PaletteSection] {
    if rows.isEmpty { return [] }

    let inlineScoreFloor: Double?
    if let minimumInlineScoreRatio,
       rows.count > perType,
       let bestScore = rows.map(\.score).max(),
       bestScore > 0 {
        inlineScoreFloor = bestScore * minimumInlineScoreRatio
    } else {
        inlineScoreFloor = nil
    }

    var buckets: [EntryType: [(entry: Entry, score: Double)]] = [:]
    for row in rows { buckets[row.entry.type, default: []].append(row) }

    let effectiveOrder: [EntryType]
    if let promote, order.contains(promote) {
        effectiveOrder = [promote] + order.filter { $0 != promote }
    } else {
        effectiveOrder = order
    }

    var out: [PaletteSection] = []
    for meta in effectiveOrder {
        guard var bucket = buckets[meta], !bucket.isEmpty else { continue }
        // Deterministic within-bucket order (tiebreak by path) so identical
        // searches render identically run-to-run.
        bucket.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry.path < $1.entry.path }
        let inlineBucket = inlineScoreFloor.map { floor in
            bucket.filter { $0.score >= floor }
        } ?? bucket
        out.append(PaletteSection(
            type: meta,
            total: bucket.count,
            top: inlineBucket.prefix(perType).map { $0.entry }
        ))
    }
    return out
}
