import Foundation
import GRDB

extension TermIndex {
    /// A separate reader sees the last committed index even during a rebuild.
    /// Keep SQL and graph traversal off the UI actor, and propagate cancellation.
    public nonisolated func expandedQueries(_ query: String, depth: Int) async throws -> [String] {
        let path = databasePath
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard depth > 0, FileManager.default.fileExists(atPath: path) else { return [query] }
            var config = Configuration()
            config.readonly = true
            config.busyMode = .timeout(5)
            let reader = try DatabaseQueue(path: path, configuration: config)
            return try reader.read { db in
                let normalized = TermParser.key(query)
                let keys = try String.fetchAll(db, sql: """
                    SELECT DISTINCT chinese_key AS term FROM pairs WHERE instr(?, chinese_key) > 0
                    UNION SELECT DISTINCT english_key AS term FROM pairs WHERE instr(?, english_key) > 0
                    """, arguments: [normalized, normalized])
                // Prefer the longest glossary phrase at each position. English
                // terms must end at word boundaries ("art" must not match "party").
                var spans: [(key: String, range: Range<String.Index>)] = []
                for key in keys.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }) {
                    try Task.checkCancellation()
                    guard !key.isEmpty else { continue }
                    var start = normalized.startIndex
                    while start < normalized.endIndex,
                          let range = normalized.range(of: key, range: start..<normalized.endIndex) {
                        start = range.upperBound
                        if Self.isWordCharacter(key.first), range.lowerBound > normalized.startIndex,
                           Self.isWordCharacter(normalized[normalized.index(before: range.lowerBound)]) { continue }
                        if Self.isWordCharacter(key.last), range.upperBound < normalized.endIndex,
                           Self.isWordCharacter(normalized[range.upperBound]) { continue }
                        if !spans.contains(where: { $0.range.overlaps(range) }) { spans.append((key, range)) }
                    }
                }
                var queries = [query]
                var seen = Set([normalized])
                for span in spans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                    let terms = try Self.relatedTerms(span.key, depth: depth, db: db)
                    for term in terms {
                        let expanded = String(normalized[..<span.range.lowerBound]) + term
                            + String(normalized[span.range.upperBound...])
                        if seen.insert(expanded).inserted { queries.append(expanded) }
                    }
                }
                return queries
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.unicodeScalars.allSatisfy(\.isASCII)
            && (character.isLetter || character.isNumber || character == "_")
    }

    private nonisolated static func relatedTerms(_ key: String, depth: Int, db: Database) throws -> [String] {
        var seen: Set<String> = [key]
        var frontier = [key]
        var result: [String] = []
        for _ in 0..<depth {
            try Task.checkCancellation()
            if frontier.isEmpty { break }
            var next = Set<String>()
            for term in frontier {
                try Task.checkCancellation()
                // Count a pair once per document. Check the sole-candidate
                // exception before filtering visited terms or limiting to five.
                let candidates = try String.fetchAll(db, sql: """
                    WITH candidates AS (
                        SELECT english_key AS term, path FROM pairs WHERE chinese_key = ?
                        UNION ALL
                        SELECT chinese_key AS term, path FROM pairs WHERE english_key = ?
                    ), frequencies AS (
                        SELECT term, COUNT(DISTINCT path) AS frequency,
                            COUNT(*) OVER () AS candidate_count
                        FROM candidates GROUP BY term
                    )
                    SELECT term FROM frequencies
                    WHERE frequency > 1 OR candidate_count = 1
                    ORDER BY frequency DESC, term ASC LIMIT 5
                    """, arguments: [term, term])
                next.formUnion(candidates.filter { !seen.contains($0) })
            }
            frontier = next.sorted()
            seen.formUnion(next)
            result.append(contentsOf: frontier)
        }
        return result
    }
}
