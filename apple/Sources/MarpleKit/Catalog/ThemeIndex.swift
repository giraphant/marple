import Foundation

public struct ThemeCount: Sendable, Equatable, Identifiable {
    public let theme: String
    public let count: Int
    public var id: String { theme }
    public init(theme: String, count: Int) { self.theme = theme; self.count = count }
}

/// Distinct themes across all entries with their occurrence counts, ordered by
/// count desc then locale-aware name asc.
public func themeCounts(_ entries: [Entry]) -> [ThemeCount] {
    var counts: [String: Int] = [:]
    for e in entries {
        for raw in e.themes {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            counts[t, default: 0] += 1
        }
    }
    return counts.map { ThemeCount(theme: $0.key, count: $0.value) }
        .sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.theme.compare(b.theme, options: [], range: nil,
                                   locale: Locale(identifier: "zh_Hans_CN")) == .orderedAscending
        }
}
