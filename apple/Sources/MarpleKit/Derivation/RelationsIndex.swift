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
        guard e.type == .paperAnalysis || e.type == .bookOverview else { continue }
        for name in splitAuthors(e.author) {
            idx[name.lowercased(), default: []].append(e)
        }
    }
    return idx
}

/// target path → note entries annotating it.
public func buildAnnotationIndex(_ entries: [Entry]) -> [String: [Entry]] {
    var idx: [String: [Entry]] = [:]
    for e in entries where e.type == .note {
        if let target = e.annotates, !target.isEmpty {
            idx[target, default: []].append(e)
        }
    }
    return idx
}

public struct Relations: Equatable, Sendable {
    public var works: [Entry] = []          // author-profile: all works by this author
    public var siblings: [Entry] = []       // paper/book: other works by same author(s)
    public var similar: [Entry] = []        // same-type entries sharing ≥2 themes (cap 6)
    public var annotations: [Entry] = []    // notes whose `annotates` == this path
    public var authorProfile: Entry?        // paper/book: matching author-profile entry
    public init() {}
}

private func byRatingDesc(_ a: Entry, _ b: Entry) -> Bool { a.ratingScore > b.ratingScore }

/// Compute knowledge relations for `entry`. Ports the PropertyPanel backlinks memo.
public func relations(for entry: Entry, in entries: [Entry],
                      authorIndex: [String: [Entry]],
                      annotationIndex: [String: [Entry]]) -> Relations {
    var out = Relations()
    out.annotations = (annotationIndex[entry.path] ?? []).sorted(by: byRatingDesc)

    if entry.type == .authorProfile {
        let key = (entry.title ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        out.works = key.isEmpty ? [] : (authorIndex[key] ?? [])
            .filter { $0.path != entry.path }
            .sorted(by: byRatingDesc)
    }

    if entry.type == .paperAnalysis || entry.type == .bookOverview {
        var siblings: [Entry] = []
        var seen = Set<String>()
        for name in splitAuthors(entry.author) {
            let key = name.lowercased()
            if out.authorProfile == nil {
                out.authorProfile = entries.first {
                    $0.type == .authorProfile && ($0.title ?? "").lowercased() == key
                }
            }
            for w in authorIndex[key] ?? [] where w.path != entry.path && !seen.contains(w.path) {
                seen.insert(w.path); siblings.append(w)
            }
        }
        out.siblings = siblings.sorted(by: byRatingDesc)

        let own = Set(entry.themes)
        if own.count >= 2 {
            var scored: [(n: Int, entry: Entry)] = []
            for e in entries where e.path != entry.path && e.type == entry.type {
                let n = e.themes.filter { own.contains($0) }.count
                if n >= 2 { scored.append((n, e)) }
            }
            scored.sort { $0.n != $1.n ? $0.n > $1.n : $0.entry.ratingScore > $1.entry.ratingScore }
            out.similar = scored.prefix(6).map(\.entry)
        }
    }
    return out
}
