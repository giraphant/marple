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

/// authorName(lowercased) → entries authored by that name.
public func buildAuthorIndex(_ entries: [Entry]) -> [String: [Entry]] {
    var idx: [String: [Entry]] = [:]
    for e in entries {
        guard e.type == .paper || e.type == .book else { continue }
        for name in e.author {
            idx[name.lowercased(), default: []].append(e)
        }
    }
    return idx
}

public func annotationAnchor(for entry: Entry, in entries: [Entry]) -> Entry {
    let overviewBySlug = bookOverviewBySlug(entries)
    return annotationAnchor(for: entry, overviewBySlug: overviewBySlug)
}

/// target path → note entries annotating it.
public func buildAnnotationIndex(_ entries: [Entry]) -> [String: [Entry]] {
    var idx: [String: [Entry]] = [:]
    let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    let overviewBySlug = bookOverviewBySlug(entries)
    for e in entries where e.type == .note {
        if let target = e.annotates, !target.isEmpty {
            let anchor = byPath[target].map { annotationAnchor(for: $0, overviewBySlug: overviewBySlug).path } ?? target
            idx[anchor, default: []].append(e)
        }
    }
    return idx
}

private func bookOverviewBySlug(_ entries: [Entry]) -> [String: Entry] {
    var out: [String: Entry] = [:]
    for e in entries where e.type == .book {
        if let slug = bookSlug(e.path), out[slug] == nil { out[slug] = e }
    }
    return out
}

private func annotationAnchor(for entry: Entry, overviewBySlug: [String: Entry]) -> Entry {
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
                      authorIndex: [String: [Entry]],
                      annotationIndex: [String: [Entry]],
                      topicMembership: TopicMembership = TopicMembership()) -> Relations {
    var out = Relations()
    let liveAuthorIndex = authorIndex.isEmpty ? buildAuthorIndex(entries) : authorIndex
    let anchor = annotationAnchor(for: entry, in: entries)
    out.annotations = (annotationIndex[anchor.path] ?? []).sorted(by: byRatingDesc)

    if entry.type == .topic, let slug = topicSlug(entry.path) {
        out.topicMembers = (topicMembership.membersBySlug[slug] ?? [])
            .filter { $0.path != entry.path && relationPanelType($0) != nil }
            .sorted(by: byRatingDesc)
    }

    if entry.type == .author {
        let key = (entry.title ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        out.works = key.isEmpty ? [] : (liveAuthorIndex[key] ?? [])
            .filter { $0.path != entry.path }
            .sorted(by: byRatingDesc)
    }

    let relationEntry = entry.type == .chapter ? bookContext(for: entry, in: entries)?.overview : entry
    if let relationEntry, relationEntry.type == .paper || relationEntry.type == .book {
        var siblings: [Entry] = []
        var seen = Set<String>()
        for name in relationEntry.author {
            let key = name.lowercased()
            if out.authorProfile == nil {
                out.authorProfile = entries.first {
                    $0.type == .author && ($0.title ?? "").lowercased() == key
                }
            }
            for w in liveAuthorIndex[key] ?? []
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
