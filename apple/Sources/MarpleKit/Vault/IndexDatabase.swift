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
///
/// QUA-104: `loadEntries` consults a sibling `.marple/entries.cache` (a binary
/// plist snapshot of [Entry]) before running the 17-col × 15k-row SELECT.
/// A monotonic `meta.entries_revision` counter in SQLite arbitrates freshness:
/// match → cache hit, mismatch → SQL path + async cache rewrite. The cache is
/// nuked by VaultIndexer.buildFull and bumped by reconcile, so it self-heals.
public final class IndexDatabase: @unchecked Sendable {
    public let indexDBPath: String
    private let lock = NSLock()
    private var cachedQueue: DatabaseQueue?

    /// Serialises cache rewrites so two concurrent loadEntries that both saw
    /// a miss don't race on the temp-rename target. Concurrent reads are fine —
    /// only the write path needs single-flight.
    private let cacheWriteLock = NSLock()

    public init(indexDBPath: String) { self.indexDBPath = indexDBPath }

    /// Sidecar binary plist of `[Entry]`, kept in sync with `entries_revision`.
    private var entriesCachePath: String {
        // .marple/index.sqlite → .marple/entries.cache
        (indexDBPath as NSString).deletingLastPathComponent + "/entries.cache"
    }

    /// Bump this when the on-disk cache format (header layout, encoder choice,
    /// Entry's required Codable shape) changes incompatibly with prior builds.
    /// Optional Entry fields added with safe `decodeIfPresent` do NOT require a
    /// bump — old caches still decode, missing fields default to nil/empty.
    /// Required new fields, encoder swaps, or header rearrangement DO require a bump.
    private static let cacheFormatVersion: UInt32 = 1

    /// 8-byte ASCII magic "MARPLE\0C" — guards against decoding a foreign file
    /// that happened to land at this path.
    private static let cacheMagic: [UInt8] = [0x4D, 0x41, 0x52, 0x50, 0x4C, 0x45, 0x00, 0x43]

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

        // 1. Read the current revision via the cached queue. The WAL snapshot
        //    inside the `read` block guarantees this number describes the
        //    `entries` rows we would observe in this same transaction.
        let revision: Int64 = try queue.read { db in
            guard try db.tableExists("entries") else { return Int64(-1) }
            return try IndexWriter.entriesRevision(db)
        }
        // entries table absent → empty result, no cache work needed.
        if revision < 0 { return [] }

        // 2. Try cache hit. On any failure (missing, wrong magic, version
        //    mismatch, revision mismatch, decode error), fall through to SQL.
        let cacheStart = Date()
        if let cached = try? readCache(expectedRevision: revision) {
            let ms = Int(Date().timeIntervalSince(cacheStart) * 1000)
            print("[marple] loadEntries: cache HIT (\(cached.count) entries, rev=\(revision), \(ms) ms)")
            return cached
        }

        // 3. SQL path. ORDER BY path keeps cache order stable across
        //    rebuilds — without it SQLite's row order is whatever the
        //    underlying b-tree happens to hand back.
        let sqlStart = Date()
        let entries = try queue.read { db -> [Entry] in
            guard try db.tableExists("entries") else { return [] }
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
                ORDER BY path
                """)
            while let row = try cursor.next() {
                result.append(Self.entry(from: row))
            }
            return result
        }

        let sqlMs = Int(Date().timeIntervalSince(sqlStart) * 1000)
        print("[marple] loadEntries: cache MISS → SQL (\(entries.count) entries, rev=\(revision), \(sqlMs) ms) — rewriting cache async")

        // 4. Schedule async cache write. We don't block the caller — even a
        //    slow encode (~50 ms for 15k entries) is amortized away from boot.
        let cachePath = entriesCachePath
        let revisionForWrite = revision
        let entriesForWrite = entries
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.writeCacheBestEffort(entries: entriesForWrite,
                                       revision: revisionForWrite,
                                       cachePath: cachePath)
        }
        return entries
    }

    // MARK: - Cache I/O

    /// Read and validate the cache file. Throws on any structural issue so
    /// callers can `try?` and fall through to SQL. Also deletes a broken file
    /// so the next loadEntries doesn't keep replaying the failure.
    private func readCache(expectedRevision: Int64) throws -> [Entry] {
        let path = entriesCachePath
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            // Not existing is the normal first-boot case — propagate up so
            // the caller falls back. Don't delete a file that wasn't there.
            throw error
        }
        do {
            let entries = try Self.decodeCachePayload(data, expectedRevision: expectedRevision)
            return entries
        } catch {
            // Corrupt / version mismatch / revision mismatch. Wipe so future
            // boots take the fresh SQL path until the next write succeeds.
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    enum CacheReadError: Error, Equatable {
        case shortHeader
        case badMagic
        case versionMismatch(expected: UInt32, got: UInt32)
        case revisionMismatch(expected: Int64, got: Int64)
        case payloadDecode
    }

    static func decodeCachePayload(_ data: Data, expectedRevision: Int64) throws -> [Entry] {
        let headerLen = cacheMagic.count + 4 /* version */ + 8 /* revision */ + 4 /* payload count */
        guard data.count >= headerLen else { throw CacheReadError.shortHeader }
        var cursor = 0
        for b in cacheMagic {
            if data[data.startIndex + cursor] != b { throw CacheReadError.badMagic }
            cursor += 1
        }
        let version = data.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self).littleEndian
        }
        cursor += 4
        guard version == cacheFormatVersion else {
            throw CacheReadError.versionMismatch(expected: cacheFormatVersion, got: version)
        }
        let revision = data.withUnsafeBytes { raw -> Int64 in
            Int64(bitPattern: raw.loadUnaligned(fromByteOffset: cursor, as: UInt64.self).littleEndian)
        }
        cursor += 8
        guard revision == expectedRevision else {
            throw CacheReadError.revisionMismatch(expected: expectedRevision, got: revision)
        }
        let payloadLen = data.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self).littleEndian
        }
        cursor += 4
        guard data.count >= cursor + Int(payloadLen) else { throw CacheReadError.shortHeader }
        let payload = data.subdata(in: cursor..<(cursor + Int(payloadLen)))
        do {
            return try PropertyListDecoder().decode([Entry].self, from: payload)
        } catch {
            throw CacheReadError.payloadDecode
        }
    }

    /// Encode `[Entry]` to the on-disk format and atomically replace the cache
    /// file. Best-effort: failures are swallowed (logged) — next boot will pay
    /// the SQL cost again and retry. UUID-suffixed temp file so two concurrent
    /// rebuilds don't clobber each other.
    private func writeCacheBestEffort(entries: [Entry], revision: Int64, cachePath: String) {
        cacheWriteLock.lock(); defer { cacheWriteLock.unlock() }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let payload = try encoder.encode(entries)

            var blob = Data()
            blob.reserveCapacity(Self.cacheMagic.count + 16 + payload.count)
            blob.append(contentsOf: Self.cacheMagic)
            var v = Self.cacheFormatVersion.littleEndian
            withUnsafeBytes(of: &v) { blob.append(contentsOf: $0) }
            var r = UInt64(bitPattern: revision).littleEndian
            withUnsafeBytes(of: &r) { blob.append(contentsOf: $0) }
            var len = UInt32(payload.count).littleEndian
            withUnsafeBytes(of: &len) { blob.append(contentsOf: $0) }
            blob.append(payload)

            let tmp = cachePath + ".\(UUID().uuidString).tmp"
            try blob.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            // Atomic rename on top of the live file (POSIX rename semantics).
            if FileManager.default.fileExists(atPath: cachePath) {
                try? FileManager.default.removeItem(atPath: cachePath)
            }
            try FileManager.default.moveItem(atPath: tmp, toPath: cachePath)
        } catch {
            print("[marple] entries cache write failed (non-fatal): \(error)")
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
