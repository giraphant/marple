import Foundation

public enum FilterField: String, Sendable, CaseIterable, Hashable, Codable {
    case rating, year, author, theme, source, haspdf, added

    public var label: String {
        switch self {
        case .rating: return "评分"
        case .year:   return "年份"
        case .author: return "作者"
        case .theme:  return "标签"
        case .source: return "来源"
        case .haspdf: return "有 PDF"
        case .added:  return "入库"
        }
    }

    /// Value input kind: text, number, or none (haspdf is a pure predicate).
    public var input: FilterInput {
        switch self {
        case .rating, .year, .added: return .number
        case .author, .theme, .source: return .text
        case .haspdf: return .none
        }
    }
}

public enum FilterInput: Sendable { case number, text, none }
public enum FilterOp: String, Sendable, Hashable, Codable { case gte, lte, eq, contains, is_ = "is", yes, within }
public enum FilterMatch: String, Sendable, Hashable, Codable { case all, any }

public struct FilterClause: Sendable, Equatable, Hashable, Identifiable, Codable {
    public let id: String
    public var field: FilterField
    public var op: FilterOp
    public var value: String
    public init(id: String = UUID().uuidString, field: FilterField, op: FilterOp, value: String) {
        self.id = id; self.field = field; self.op = op; self.value = value
    }
}

private func toNum(_ s: String?) -> Double? {
    guard let s, !s.isEmpty else { return nil }
    return Double(s)
}

/// True when a clause has enough input to actually filter.
public func clauseReady(_ c: FilterClause) -> Bool {
    switch c.field.input {
    case .none:   return true
    case .number: return toNum(c.value.trimmingCharacters(in: .whitespaces)) != nil
    case .text:   return !c.value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

private func test(_ e: Entry, _ c: FilterClause, now: Date) -> Bool {
    switch c.field {
    case .rating:
        guard let want = toNum(c.value) else { return true }
        let got = e.ratingScore
        switch c.op { case .lte: return got <= want; case .eq: return got == want; default: return got >= want }
    case .year:
        guard let want = toNum(c.value) else { return true }
        guard let got = toNum(e.year) else { return false }
        switch c.op { case .lte: return got <= want; case .eq: return got == want; default: return got >= want }
    case .author:
        // Match if any author contains the query (case-insensitive). Multi-
        // author entries should still surface when the user filters by one
        // of their names.
        let needle = c.value.trimmingCharacters(in: .whitespaces).lowercased()
        return e.author.contains { $0.lowercased().contains(needle) }
    case .theme:
        let v = c.value.trimmingCharacters(in: .whitespaces).lowercased()
        return c.op == .is_ ? e.themes.contains { $0.lowercased() == v }
                            : e.themes.contains { $0.lowercased().contains(v) }
    case .source:
        let v = c.value.trimmingCharacters(in: .whitespaces).lowercased()
        let src = (e.source ?? "").lowercased()
        return c.op == .is_ ? src == v : src.contains(v)
    case .haspdf:
        return e.hasPDF
    case .added:
        guard let days = toNum(c.value), let added = e.added else { return false }
        return now.timeIntervalSince1970 * 1000 - added <= days * 86_400_000
    }
}

/// Apply ready clauses; incomplete clauses are ignored so half-typed rows
/// don't blank the list. `now` is injectable for deterministic tests.
public func applyFilters(_ list: [Entry], _ clauses: [FilterClause],
                         match: FilterMatch, now: Date = Date()) -> [Entry] {
    let active = clauses.filter(clauseReady)
    guard !active.isEmpty else { return list }
    return list.filter { e in
        match == .all ? active.allSatisfy { test(e, $0, now: now) }
                      : active.contains { test(e, $0, now: now) }
    }
}

/// Short human label for a chip, e.g. "评分 ≥ 3".
public func clauseLabel(_ c: FilterClause) -> String {
    if c.field == .haspdf { return "有 PDF" }
    if c.field == .added { return "入库近 \(c.value) 天" }
    let opLabel: String
    switch c.op {
    case .gte: opLabel = "≥"; case .lte: opLabel = "≤"; case .eq: opLabel = "="
    case .contains: opLabel = "包含"; case .is_: opLabel = "是"
    case .yes: opLabel = ""; case .within: opLabel = ""
    }
    return "\(c.field.label) \(opLabel) \(c.value)".trimmingCharacters(in: .whitespaces)
}
