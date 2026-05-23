import Foundation

public enum SortField: String, Sendable, CaseIterable, Hashable, Codable {
    case rating, year, added, updated, title, author

    public var label: String {
        switch self {
        case .rating:  return "评分"
        case .year:    return "年份"
        case .added:   return "入库时间"
        case .updated: return "更新时间"
        case .title:   return "标题"
        case .author:  return "作者"
        }
    }

    /// Sensible default direction when the user picks this field.
    public var defaultDir: SortDir { (self == .title || self == .author) ? .asc : .desc }
}

public enum SortDir: String, Sendable, Hashable, Codable { case asc, desc }

public struct SortClause: Sendable, Equatable, Hashable, Codable {
    public var field: SortField
    public var dir: SortDir
    public init(field: SortField, dir: SortDir) { self.field = field; self.dir = dir }
}

private func textCmp(_ a: String?, _ b: String?, _ dir: SortDir) -> Int {
    let ea = (a ?? "").isEmpty, eb = (b ?? "").isEmpty
    if ea && eb { return 0 }
    if ea { return 1 }            // empties last
    if eb { return -1 }
    let c = a!.compare(b!, options: [.caseInsensitive], range: nil, locale: Locale(identifier: "zh_Hans_CN"))
    let r = c == .orderedAscending ? -1 : (c == .orderedDescending ? 1 : 0)
    return dir == .asc ? r : -r
}

private func numCmp(_ a: Double?, _ b: Double?, _ dir: SortDir) -> Int {
    let ea = a == nil, eb = b == nil
    if ea && eb { return 0 }
    if ea { return 1 }            // empties last
    if eb { return -1 }
    let r = a! < b! ? -1 : (a! > b! ? 1 : 0)
    return dir == .asc ? r : -r
}

private func toNum(_ s: String?) -> Double? {
    guard let s, !s.isEmpty else { return nil }
    return Double(s)
}

private func comparator(_ field: SortField, _ dir: SortDir) -> (Entry, Entry) -> Int {
    switch field {
    case .title:   return { textCmp($0.title, $1.title, dir) }
    case .author:  return { textCmp($0.author, $1.author, dir) }
    case .year:    return { numCmp(toNum($0.year), toNum($1.year), dir) }
    // ratingScore 0 means "unrated" → treat as empty so it sorts last either way.
    case .rating:  return { numCmp($0.ratingScore == 0 ? nil : $0.ratingScore,
                                   $1.ratingScore == 0 ? nil : $1.ratingScore, dir) }
    case .updated: return { numCmp($0.mtime, $1.mtime, dir) }
    case .added:   return { numCmp($0.added, $1.added, dir) }
    }
}

/// Multi-level stable sort. Empty clause list returns the input unchanged.
/// Ties fall through to the next clause, then to original index.
public func sortEntries(_ list: [Entry], by clauses: [SortClause]) -> [Entry] {
    guard !clauses.isEmpty else { return list }
    let cmps = clauses.map { comparator($0.field, $0.dir) }
    return list.enumerated().sorted { lhs, rhs in
        for cmp in cmps {
            let r = cmp(lhs.element, rhs.element)
            if r != 0 { return r < 0 }
        }
        return lhs.offset < rhs.offset
    }.map(\.element)
}
