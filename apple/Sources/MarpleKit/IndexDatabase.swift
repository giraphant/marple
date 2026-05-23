import Foundation
import GRDB

/// Read-only view of the SQLite index (`<workspaceRoot>/.marple/index.sqlite`)
/// that the background indexer maintains. Opens read-only with a busy timeout so
/// reads never collide with the indexer's WAL writes. Best-effort: a missing file
/// or table yields empty results rather than throwing, so the app degrades to
/// "no metadata yet" on first run instead of crashing.
public struct IndexDatabase: Sendable {
    public let indexDBPath: String
    public init(indexDBPath: String) { self.indexDBPath = indexDBPath }

    private func openQueue() throws -> DatabaseQueue? {
        guard FileManager.default.fileExists(atPath: indexDBPath) else { return nil }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        return try DatabaseQueue(path: indexDBPath, configuration: config)
    }

    public func loadEntries() throws -> [Entry] {
        guard let queue = try openQueue() else { return [] }
        return try queue.read { db in
            guard try db.tableExists("entries") else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT path, type, book, title, author, year_json, rating_score,
                       themes_json, topic, source, doi, annotates, has_pdf, mtime, preview, added
                FROM entries
                """)
            return rows.map(Self.entry(from:))
        }
    }

    public func search(_ q: String, type: EntryType?, minRating: Double?,
                       theme: String?, limit: Int) throws -> [SearchHit] {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let queue = try openQueue() else { return [] }
        // FTS5 trigram needs ≥ 3 characters to form a trigram; for shorter queries
        // (common with CJK bigrams like "量表") fall back to a LIKE scan.
        let canUseFTS = trimmed.unicodeScalars.count >= 3
        return try queue.read { db in
            guard try db.tableExists("entry_trigram"), try db.tableExists("entries") else { return [] }
            if canUseFTS {
                return try Self.searchViaFTS(db: db, trimmed: trimmed, type: type,
                                             minRating: minRating, theme: theme, limit: limit)
            } else {
                return try Self.searchViaLike(db: db, trimmed: trimmed, type: type,
                                              minRating: minRating, theme: theme, limit: limit)
            }
        }
    }

    private static func searchViaFTS(db: Database, trimmed: String, type: EntryType?,
                                     minRating: Double?, theme: String?,
                                     limit: Int) throws -> [SearchHit] {
        let match = ftsPhrase(trimmed)
        var sql = """
            SELECT e.path AS path, e.type AS type, e.book AS book, e.title AS title,
                   e.author AS author, e.year_json AS year_json, e.rating_score AS rating_score,
                   e.themes_json AS themes_json, e.topic AS topic, e.source AS source,
                   e.doi AS doi, e.annotates AS annotates, e.has_pdf AS has_pdf,
                   e.mtime AS mtime, e.preview AS preview, e.added AS added,
                   bm25(entry_trigram) AS score,
                   snippet(entry_trigram, 2, '〔', '〕', '…', 8) AS snip
            FROM entry_trigram
            JOIN entries e ON e.path = entry_trigram.path
            WHERE entry_trigram MATCH ?
            """
        var args: [(any DatabaseValueConvertible)?] = [match]
        if let type { sql += "\n  AND e.type = ?"; args.append(type.rawValue) }
        if let minRating { sql += "\n  AND e.rating_score >= ?"; args.append(minRating) }
        if let theme {
            sql += "\n  AND e.path IN (SELECT path FROM entry_themes WHERE theme = ?)"
            args.append(theme)
        }
        sql += "\nORDER BY score\nLIMIT ?"
        args.append(limit)
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return rows.map { row in
            let score: Double = row["score"] ?? 0
            let snip: String? = row["snip"]
            return SearchHit(entry: Self.entry(from: row), score: score,
                             snippet: snip, source: "trigram")
        }
    }

    private static func searchViaLike(db: Database, trimmed: String, type: EntryType?,
                                      minRating: Double?, theme: String?,
                                      limit: Int) throws -> [SearchHit] {
        let pattern = "%" + trimmed + "%"
        var sql = """
            SELECT e.path AS path, e.type AS type, e.book AS book, e.title AS title,
                   e.author AS author, e.year_json AS year_json, e.rating_score AS rating_score,
                   e.themes_json AS themes_json, e.topic AS topic, e.source AS source,
                   e.doi AS doi, e.annotates AS annotates, e.has_pdf AS has_pdf,
                   e.mtime AS mtime, e.preview AS preview, e.added AS added,
                   0.0 AS score,
                   NULL AS snip
            FROM entry_trigram t
            JOIN entries e ON e.path = t.path
            WHERE t.text LIKE ?
            """
        var args: [(any DatabaseValueConvertible)?] = [pattern]
        if let type { sql += "\n  AND e.type = ?"; args.append(type.rawValue) }
        if let minRating { sql += "\n  AND e.rating_score >= ?"; args.append(minRating) }
        if let theme {
            sql += "\n  AND e.path IN (SELECT path FROM entry_themes WHERE theme = ?)"
            args.append(theme)
        }
        sql += "\nLIMIT ?"
        args.append(limit)
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return rows.map { row in
            let snip: String? = row["snip"]
            return SearchHit(entry: Self.entry(from: row), score: 0,
                             snippet: snip, source: "trigram-like")
        }
    }

    /// Map one `entries` row (or a search-join row aliased to the same names) to `Entry`.
    static func entry(from row: Row) -> Entry {
        let themesJSON: String? = row["themes_json"]
        let themes: [String] = themesJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let yearJSON: String? = row["year_json"]
        let year: String? = decodeYear(yearJSON)
        let mtimeRaw: Int64? = row["mtime"]
        let addedRaw: Int64? = row["added"]
        let mtime: Double? = mtimeRaw.map(Double.init)
        let added: Double? = addedRaw.map(Double.init)
        let hasPDFRaw: Int64? = row["has_pdf"]
        let ratingScore: Double = row["rating_score"] ?? 0
        let path: String = row["path"]
        let typeRaw: String = row["type"]
        let title: String? = row["title"]
        let author: String? = row["author"]
        let preview: String = (row["preview"] as String?) ?? ""
        let source: String? = row["source"]
        let book: String? = row["book"]
        let topic: String? = row["topic"]
        let doi: String? = row["doi"]
        let annotates: String? = row["annotates"]
        return Entry(
            path: path,
            type: EntryType(rawValue: typeRaw),
            title: title,
            author: author,
            year: year,
            ratingScore: ratingScore,
            themes: themes,
            preview: preview,
            hasPDF: (hasPDFRaw ?? 0) != 0,
            mtime: mtime,
            added: added,
            source: source,
            book: book,
            topic: topic,
            doi: doi,
            annotates: annotates
        )
    }

    /// `year_json` holds a JSON scalar ("2014", 2014, 2014.0) or null. Mirror the
    /// HTTP path: stringify a scalar, drop anything else.
    static func decodeYear(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        if let s = try? JSONDecoder().decode(String.self, from: data) { return s }
        if let i = try? JSONDecoder().decode(Int.self, from: data) { return String(i) }
        if let d = try? JSONDecoder().decode(Double.self, from: data) { return String(Int(d)) }
        let raw = json.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return raw.isEmpty || raw == "null" ? nil : raw
    }

    /// Wrap user input as a single FTS5 phrase, doubling embedded quotes. Trigram
    /// matches it as a substring (CJK-safe) and this neutralizes FTS5 operators.
    static func ftsPhrase(_ q: String) -> String {
        "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
