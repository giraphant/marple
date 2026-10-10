import Foundation

/// Reciprocal rank fusion compares positions, not incomparable FTS/vector scores.
/// Each query contributes once per path; ties keep the original query's order.
public func fuseSearchHits(_ lists: [[SearchHit]]) -> [SearchHit] {
    guard lists.count > 1 else { return lists.first ?? [] }
    var hits: [String: SearchHit] = [:]
    var scores: [String: Double] = [:]
    var order: [String: Int] = [:]
    for list in lists {
        var seen = Set<String>()
        for (rank, hit) in list.enumerated() where seen.insert(hit.entry.path).inserted {
            let path = hit.entry.path
            if hits[path] == nil { hits[path] = hit; order[path] = order.count }
            scores[path, default: 0] += 1 / Double(60 + rank + 1)
        }
    }
    return hits.values.map { hit in
        SearchHit(entry: hit.entry, score: scores[hit.entry.path]!, snippet: hit.snippet, source: hit.source)
    }.sorted {
        $0.score == $1.score ? order[$0.entry.path]! < order[$1.entry.path]! : $0.score > $1.score
    }
}
