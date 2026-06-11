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

public func annotationAnchor(for entry: Entry, in entries: [Entry]) -> Entry {
    let overviewBySlug = bookOverviewBySlug(entries)
    return annotationAnchor(for: entry, overviewBySlug: overviewBySlug)
}

func bookOverviewBySlug(_ entries: [Entry]) -> [String: Entry] {
    var out: [String: Entry] = [:]
    for e in entries where e.type == .book {
        if let slug = bookSlug(e.path), out[slug] == nil { out[slug] = e }
    }
    return out
}

func annotationAnchor(for entry: Entry, overviewBySlug: [String: Entry]) -> Entry {
    if entry.type == .chapter {
        let slug = entry.book ?? bookSlug(entry.path)
        if let slug, let overview = overviewBySlug[slug] { return overview }
    }
    return entry
}

public struct Relations: Equatable, Sendable {
    public var works: [Entry] = []          // author: all works by this author
    public var siblings: [Entry] = []       // paper/book: other works by same author(s)
    public var similar: [Entry] = []        // same-type entries sharing ≥2 themes (cap 6)
    public var annotations: [Entry] = []    // notes keyed by this entry's annotation anchor
    public var topicMembers: [Entry] = []   // topic: entries declaring membership via `topics:`
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
    // annotations 沿用旧时序：只读传入的图，未就绪即空（旧 annotationIndex 无回退）。
    let liveGraph = graph.isEmpty ? RelationGraph.build(entries) : graph
    let anchor = annotationAnchor(for: entry, in: entries)
    out.annotations = graph.sources(of: anchor.path, kind: .annotates).sorted(by: byRatingDesc)

    if entry.type == .topic, let slug = topicSlug(entry.path) {
        out.topicMembers = (topicMembership.membersBySlug[slug] ?? [])
            .filter { $0.path != entry.path && relationPanelType($0) != nil }
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
