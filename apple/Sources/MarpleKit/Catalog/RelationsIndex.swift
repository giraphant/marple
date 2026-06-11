import Foundation

/// Split a joined author string into names. Mirrors src/wiki.ts splitAuthors:
/// separators are "," or " & " or " and " (case-insensitive).
public func splitAuthors(_ s: String?) -> [String] {
    guard let s, !s.isEmpty else { return [] }
    let regex = try! NSRegularExpression(pattern: #",| & | and "#, options: [.caseInsensitive])
    let ns = s as NSString
    var parts: [String] = []
    var last = 0
    for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
        last = m.range.location + m.range.length
    }
    parts.append(ns.substring(from: last))
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// 规则：容器附属聚合。容器 overview 的反向附属（如 annotates 笔记）=
/// 自身 ∪ 所有成员；非 overview（章节、普通文档）只取直接标注自己的。上卷只在
/// 查询期发生，边本身忠实真相——替代旧 annotationAnchor 的写入期章→书重映射
/// （QUA-221）。去重保留来源顺序（overview 自身 → 各章节，按 bookContext 序）。
func attachmentSources(for entry: Entry, in entries: [Entry],
                       graph: RelationGraph, kind: RelationKind) -> [Entry] {
    let anchors: [Entry]
    if let ctx = bookContext(for: entry, in: entries), ctx.overview?.path == entry.path {
        anchors = [entry] + ctx.chapters
    } else {
        anchors = [entry]
    }
    var seen = Set<String>()
    var acc: [Entry] = []
    for anchor in anchors {
        for n in graph.sources(of: anchor.path, kind: kind) where !seen.contains(n.path) {
            seen.insert(n.path); acc.append(n)
        }
    }
    return acc
}

public struct Relations: Equatable, Sendable {
    public var works: [Entry] = []          // author: all works by this author
    public var siblings: [Entry] = []       // paper/book: other works by same author(s)
    public var similar: [Entry] = []        // same-type entries sharing ≥2 themes (cap 6)
    public var annotations: [Entry] = []    // notes keyed by this entry's annotation anchor
    public var topicMembers: [Entry] = []   // topic: entries declaring membership via `topics:`
    public var journalArticles: [Entry] = [] // journal: papers published in this journal
    public var authorProfile: Entry?        // paper/book: matching author entry (kept named
                                            // `authorProfile` to disambiguate from `Entry.author: [String]`)
    public init() {}
}

private func byRatingDesc(_ a: Entry, _ b: Entry) -> Bool { a.ratingScore > b.ratingScore }

private func relationPanelType(_ entry: Entry) -> EntryType? {
    switch entry.type {
    case .paper, .book: return entry.type
    default: return nil
    }
}

/// Compute knowledge relations for `entry`. Ports the PropertyPanel backlinks memo.
public func relations(for entry: Entry, in entries: [Entry],
                      graph: RelationGraph,
                      topicMembership: TopicMembership = TopicMembership()) -> Relations {
    var out = Relations()
    // 旧 isEmpty 回退：deferred 图未就绪时同步重建（author 部分用）。
    // annotations 沿用旧时序：只读传入的图，未就绪即空（旧 annotationIndex 无回退，
    // 故意用 graph 非 liveGraph）。容器附属聚合把章节笔记上卷到书 overview（查询期）。
    let liveGraph = graph.isEmpty ? RelationGraph.build(entries) : graph
    out.annotations = attachmentSources(for: entry, in: entries, graph: graph, kind: .annotates)
        .sorted(by: byRatingDesc)

    // topic 成员现入图（inTopic 反向）。任何 topic 子页都归一到该 slug 的代表页
    // （overview = topicEntryBySlug），与旧 membersBySlug[slug] 的 slug-键语义一致。
    if entry.type == .topic, let slug = topicSlug(entry.path) {
        let anchor = topicMembership.topicEntryBySlug[slug] ?? entry
        out.topicMembers = liveGraph.sources(of: anchor.path, kind: .inTopic)
            .filter { $0.path != entry.path && relationPanelType($0) != nil }
            .sorted(by: byRatingDesc)
    }

    if entry.type == .journal {
        out.journalArticles = liveGraph.sources(of: entry.path, kind: .inJournal)
            .filter { $0.path != entry.path }
            .sorted(by: byRatingDesc)
    }

    if entry.type == .author {
        out.works = liveGraph.sources(of: entry.path, kind: .authoredBy)
            .filter { $0.path != entry.path }
            .sorted(by: byRatingDesc)
    }

    let relationEntry = entry.type == .chapter ? bookContext(for: entry, in: entries)?.overview : entry
    if let relationEntry, relationEntry.type == .paper || relationEntry.type == .book {
        // 旧语义：按 author 名字序扫描，首个有作者页的名字胜出 —— 建边即按
        // 名字序，且只为可解析的名字建边，所以 targets().first 等价。
        out.authorProfile = liveGraph.targets(of: relationEntry.path, kind: .authoredBy).first
        var siblings: [Entry] = []
        var seen = Set<String>()
        for name in relationEntry.author {
            let key = name.lowercased()
            for w in liveGraph.worksByAuthorKey[key] ?? []
                where w.path != relationEntry.path
                    && w.path != entry.path
                    && relationPanelType(w) != nil
                    && !seen.contains(w.path) {
                seen.insert(w.path); siblings.append(w)
            }
        }
        out.siblings = siblings.sorted(by: byRatingDesc)

        let own = Set(relationEntry.themes)
        if own.count >= 2 {
            var scored: [(n: Int, entry: Entry)] = []
            for e in entries where e.path != relationEntry.path && e.path != entry.path && e.type == relationEntry.type {
                let n = e.themes.filter { own.contains($0) }.count
                if n >= 2 { scored.append((n, e)) }
            }
            scored.sort { $0.n != $1.n ? $0.n > $1.n : $0.entry.ratingScore > $1.entry.ratingScore }
            out.similar = scored.prefix(6).map(\.entry)
        }
    }
    return out
}
