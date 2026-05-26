import Foundation
import GRDB

/// Read-only view of the SQLite index (`<workspaceRoot>/.marple/index.sqlite`)
/// that the background indexer maintains. Opens read-only with a busy timeout so
/// reads never collide with the indexer's WAL writes. Best-effort: a missing file
/// or table yields empty results rather than throwing, so the app degrades to
/// "no metadata yet" on first run instead of crashing.
///
/// Holds ONE shared `DatabaseQueue` for the lifetime of the value: reopening on
/// every call costs ~1.5 s on a 1.5 GB index (the WAL connection has to attach
/// to the -shm file and warm its page cache). Subsequent reads through the
/// cached queue see the warm cache and finish in tens of milliseconds.
public final class IndexDatabase: @unchecked Sendable {
    public let indexDBPath: String
    private let lock = NSLock()
    private var cachedQueue: DatabaseQueue?

    public init(indexDBPath: String) { self.indexDBPath = indexDBPath }

    /// Shared decoder for row mapping. `loadEntries` maps up to ~15k rows, so reuse
    /// one instance instead of allocating a `JSONDecoder` per row/field.
    private static let decoder = JSONDecoder()

    private func openQueue() throws -> DatabaseQueue? {
        lock.lock(); defer { lock.unlock() }
        if let q = cachedQueue { return q }
        // Don't cache negative results: the DB file may not exist yet at the time
        // of the first read (boot may construct IndexDatabase before reconcile
        // has finished), and we want a later read to pick it up.
        guard FileManager.default.fileExists(atPath: indexDBPath) else { return nil }
        var config = Configuration()
        // NOT read-only: the index is a WAL database written by the indexer, and a
        // read-only connection cannot open the -shm wal-index (SQLITE_CANTOPEN,
        // "unable to open database file"). A normal read-write connection attaches
        // to the shm and reads concurrently; we only ever issue reads.
        config.busyMode = .timeout(5)
        let q = try DatabaseQueue(path: indexDBPath, configuration: config)
        cachedQueue = q
        return q
    }

    public func loadEntries() throws -> [Entry] {
        guard let queue = try openQueue() else { return [] }
        return try queue.read { db in
            guard try db.tableExists("entries") else { return [] }
            let t0 = Date()
            // Stream rows via cursor + decode inline. Avoids the giant [Row]
            // allocation that fetchAll builds before we ever look at row #1 —
            // on a 15k-row * 17-col query that allocation alone is hundreds of
            // ms. Pre-reserve the result so it never reallocates as we append.
            let countRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS c FROM entries")
            let expected = (countRow?["c"] as Int?) ?? 0
            var result: [Entry] = []
            result.reserveCapacity(expected)
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT path, type, book, title, author, year_json, rating_score,
                       themes_json, topic, source, doi, annotates, has_pdf, pdf_slug,
                       mtime, preview, added
                FROM entries
                """)
            while let row = try cursor.next() {
                result.append(Self.entry(from: row))
            }
            let t1 = Date()
            print(String(format: "[loadEntries] cursor+decode=%.3fs  rows=%d",
                t1.timeIntervalSince(t0), result.count))
            return result
        }
    }

    public func search(_ q: String, type: EntryType?, minRating: Double?,
                       theme: String?, limit: Int) throws -> [SearchHit] {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let queue = try openQueue() else { return [] }
        // Split into whitespace terms and AND them (each term a substring, any
        // order) — NOT one rigid phrase, so "汽车 维修" matches text containing both
        // "汽车" and "维修" even when not adjacent. FTS5 trigram needs ≥3 chars per
        // term; if EVERY term qualifies use FTS (fast, ranked), else fall back to a
        // LIKE-AND scan (handles 1–2 char CJK terms, which are extremely common).
        let terms = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        let canUseFTS = terms.allSatisfy { $0.unicodeScalars.count >= 3 }
        return try queue.read { db in
            guard try db.tableExists("entry_trigram"), try db.tableExists("entries") else { return [] }
            if canUseFTS {
                return try Self.searchViaFTS(db: db, terms: terms, type: type,
                                             minRating: minRating, theme: theme, limit: limit)
            } else {
                return try Self.searchViaLike(db: db, terms: terms, type: type,
                                              minRating: minRating, theme: theme, limit: limit)
            }
        }
    }

    private static func searchViaFTS(db: Database, terms: [String], type: EntryType?,
                                     minRating: Double?, theme: String?,
                                     limit: Int) throws -> [SearchHit] {
        // Each term as its own quoted phrase, space-joined = implicit AND in FTS5.
        let match = terms.map(ftsPhrase).joined(separator: " ")
        var sql = """
            SELECT e.path AS path, e.type AS type, e.book AS book, e.title AS title,
                   e.author AS author, e.year_json AS year_json, e.rating_score AS rating_score,
                   e.themes_json AS themes_json, e.topic AS topic, e.source AS source,
                   e.doi AS doi, e.annotates AS annotates, e.has_pdf AS has_pdf,
                   e.pdf_slug AS pdf_slug,
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

    private static func searchViaLike(db: Database, terms: [String], type: EntryType?,
                                      minRating: Double?, theme: String?,
                                      limit: Int) throws -> [SearchHit] {
        // SQL LIKE treats `_`/`%` as wildcards. Escape them (and the escape char
        // itself) so a 1–2 char term matches the literal substring, not everything.
        func pattern(_ s: String) -> String {
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%",  with: "\\%")
                .replacingOccurrences(of: "_",  with: "\\_")
            return "%" + escaped + "%"
        }
        let likeClause = terms.map { _ in "t.text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        var sql = """
            SELECT e.path AS path, e.type AS type, e.book AS book, e.title AS title,
                   e.author AS author, e.year_json AS year_json, e.rating_score AS rating_score,
                   e.themes_json AS themes_json, e.topic AS topic, e.source AS source,
                   e.doi AS doi, e.annotates AS annotates, e.has_pdf AS has_pdf,
                   e.pdf_slug AS pdf_slug,
                   e.mtime AS mtime, e.preview AS preview, e.added AS added,
                   0.0 AS score,
                   NULL AS snip
            FROM entry_trigram t
            JOIN entries e ON e.path = t.path
            WHERE \(likeClause)
            """
        var args: [(any DatabaseValueConvertible)?] = terms.map { pattern($0) }
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
            .flatMap { try? decoder.decode([String].self, from: $0) } ?? []
        let yearJSON: String? = row["year_json"]
        let year: String? = decodeYear(yearJSON)
        let mtimeRaw: Int64? = row["mtime"]
        let addedRaw: Int64? = row["added"]
        let mtime: Double? = mtimeRaw.map(Double.init)
        let added: Double? = addedRaw.map(Double.init)
        let hasPDFRaw: Int64? = row["has_pdf"]
        let pdfSlug: String? = row["pdf_slug"]
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
            pdfSlug: pdfSlug,
            mtime: mtime,
            added: added,
            source: source,
            book: book,
            topic: topic,
            doi: doi,
            annotates: annotates
        )
    }

    /// `year_json` holds a JSON scalar ("2014", 2014, 2014.0) or null:
    /// stringify a scalar, drop anything else.
    static func decodeYear(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        if let s = try? decoder.decode(String.self, from: data) { return s }
        if let i = try? decoder.decode(Int.self, from: data) { return String(i) }
        if let d = try? decoder.decode(Double.self, from: data) { return String(Int(d)) }
        let raw = json.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return raw.isEmpty || raw == "null" ? nil : raw
    }

    /// Wrap user input as a single FTS5 phrase, doubling embedded quotes. Trigram
    /// matches it as a substring (CJK-safe) and this neutralizes FTS5 operators.
    static func ftsPhrase(_ q: String) -> String {
        "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
