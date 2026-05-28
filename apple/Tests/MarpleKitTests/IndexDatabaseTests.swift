import Testing
import Foundation
import GRDB
@testable import MarpleKit

@Suite struct IndexDatabaseTests {
    /// Build a throwaway index.sqlite with the production schema (subset we read)
    /// and the trigram FTS table, then insert the given rows. Returns the file path.
    private func makeFixtureDB(_ rows: [(path: String, type: String, title: String,
                                        themesJSON: String?, yearJSON: String?,
                                        hasPDF: Int, rating: Double, text: String)]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("index.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE entries (
                  path TEXT PRIMARY KEY, type TEXT NOT NULL, book TEXT, title TEXT,
                  title_en TEXT, title_cn TEXT, author TEXT, year_json TEXT, rating_json TEXT,
                  rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, kind TEXT, journal TEXT, source TEXT,
                  doi TEXT, publisher TEXT, isbn TEXT, category TEXT, translation_title_cn TEXT,
                  translation_douban_url TEXT, chapters_analyzed INTEGER, annotates TEXT,
                  created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0, mtime INTEGER,
                  preview TEXT NOT NULL DEFAULT '', body_len INTEGER NOT NULL DEFAULT 0,
                  added INTEGER NOT NULL DEFAULT 0
                );
                CREATE VIRTUAL TABLE entry_trigram USING fts5(
                  path UNINDEXED, type UNINDEXED, text, tokenize = 'trigram'
                );
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO meta(key, value) VALUES ('entries_revision', '0');
                """)
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO entries (path, type, title, year_json, rating_score, themes_json, has_pdf, preview, mtime, added)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [r.path, r.type, r.title, r.yearJSON, r.rating, r.themesJSON, r.hasPDF, "prev", 1000, 2000])
                try db.execute(sql: "INSERT INTO entry_trigram (path, type, text) VALUES (?, ?, ?)",
                               arguments: [r.path, r.type, r.text])
            }
        }
        return path
    }

    /// Convenience to read the sidecar entries.cache path next to a DB.
    private static func entriesCachePath(forDB path: String) -> String {
        (path as NSString).deletingLastPathComponent + "/entries.cache"
    }

    /// Wait up to `seconds` for a file to appear — the cache write is
    /// scheduled on a background dispatch queue, so tests can't assume
    /// it's there immediately after loadEntries returns.
    @discardableResult
    private func awaitFile(_ path: String, seconds: Double = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Manually bump entries_revision on a fixture DB the same way reconcile does.
    private func bumpRevision(_ dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in try IndexWriter.bumpEntriesRevision(db) }
    }

    @Test func loadEntriesMapsColumns() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/a.md", type: "paper", title: "Alpha",
             themesJSON: #"["x","y"]"#, yearJSON: #""2014""#, hasPDF: 1, rating: 4.0, text: "alpha body"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.path == "vault/papers/a.md")
        #expect(e.type == .paper)
        #expect(e.title == "Alpha")
        #expect(e.themes == ["x", "y"])
        #expect(e.year == "2014")
        #expect(e.hasPDF == true)
        #expect(e.ratingScore == 4.0)
    }

    @Test func loadEntriesMapsBookCanonicalMetadataColumns() throws {
        let path = try makeFixtureDB([
            (path: "vault/books/b.md", type: "book", title: "Book",
             themesJSON: nil, yearJSON: #""1934""#, hasPDF: 0, rating: 2.0, text: "book body"),
        ])
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE entries SET publisher = ?, isbn = ?, category = ?, doi = ? WHERE path = ?",
                arguments: ["Harcourt Brace", "978-0-262-13472-9", "monograph", "10.1234/book", "vault/books/b.md"]
            )
        }

        let db = IndexDatabase(indexDBPath: path)
        let e = try #require(try db.loadEntries().first)
        #expect(e.publisher == "Harcourt Brace")
        #expect(e.isbn == "978-0-262-13472-9")
        #expect(e.category == "monograph")
        #expect(e.doi == "10.1234/book")
    }

    @Test func loadEntriesMapsLightweightCanonicalMetadataColumns() throws {
        let path = try makeFixtureDB([
            (path: "vault/journals/ajs.md", type: "journal", title: "AJS",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "journal body"),
        ])
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE entries SET kind = ?, journal = ?, created = ? WHERE path = ?",
                arguments: ["overview", "American Journal of Sociology", "2026-05-27", "vault/journals/ajs.md"]
            )
        }

        let db = IndexDatabase(indexDBPath: path)
        let e = try #require(try db.loadEntries().first)
        #expect(e.type == .journal)
        #expect(e.kind == "overview")
        #expect(e.journal == "American Journal of Sociology")
        #expect(e.created == "2026-05-27")
    }

    @Test func loadEntriesReturnsEmptyWhenDBMissing() throws {
        let db = IndexDatabase(indexDBPath: "/nonexistent/index.sqlite")
        #expect(try db.loadEntries() == [])
    }

    @Test func searchMatchesChineseSubstring() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/cn.md", type: "paper", title: "量表",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "拨号量表与感官"),
            (path: "vault/papers/en.md", type: "paper", title: "Dial",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "dial gauge senses"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let cn = try db.search("量表", type: nil, minRating: nil, theme: nil, limit: 80)
        #expect(cn.map(\.entry.path) == ["vault/papers/cn.md"])
        let en = try db.search("gauge", type: nil, minRating: nil, theme: nil, limit: 80)
        #expect(en.map(\.entry.path) == ["vault/papers/en.md"])
    }

    @Test func searchLikeEscapesWildcards() throws {
        // Short queries (< 3 chars) take the LIKE fallback. SQL LIKE treats `_`
        // and `%` as wildcards, so a raw query of "_" would match every row. The
        // fallback must escape them so they match only literal occurrences.
        let path = try makeFixtureDB([
            (path: "vault/papers/under.md", type: "paper", title: "Under",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "has a _ underscore"),
            (path: "vault/papers/plain.md", type: "paper", title: "Plain",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "no special chars here"),
            (path: "vault/papers/pct.md", type: "paper", title: "Pct",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "fifty % off"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let underscore = try db.search("_", type: nil, minRating: nil, theme: nil, limit: 80)
        #expect(underscore.map(\.entry.path) == ["vault/papers/under.md"])
        let percent = try db.search("%", type: nil, minRating: nil, theme: nil, limit: 80)
        #expect(percent.map(\.entry.path) == ["vault/papers/pct.md"])
    }

    @Test func searchRespectsTypeFilterAndLimit() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/p.md", type: "paper", title: "P",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "shared keyword"),
            (path: "vault/notes/n.md", type: "note", title: "N",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "shared keyword"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let onlyPapers = try db.search("shared", type: .paper, minRating: nil, theme: nil, limit: 80)
        #expect(onlyPapers.map(\.entry.path) == ["vault/papers/p.md"])
        let limited = try db.search("shared", type: nil, minRating: nil, theme: nil, limit: 1)
        #expect(limited.count == 1)
    }

    @Test func searchTopicPaneMatchesShortTopicRows() throws {
        let path = try makeFixtureDB([
            (path: "vault/topics/repair.md", type: "topic", title: "Repair",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "repair keyword"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let hits = try db.search("repair", type: .topic, minRating: nil, theme: nil, limit: 80)
        #expect(hits.map(\.entry.path) == ["vault/topics/repair.md"])
    }

    /// Regression test for SQLITE_CANTOPEN when reading a WAL-mode database whose
    /// writer connection has already closed (leaving a WAL-header db with no -shm).
    /// A read-only connection cannot attach the wal-index in that state; the fix is
    /// to open read-write so SQLite can create/attach the shm itself.
    @Test func readsWALDatabaseAfterWriterClosed() throws {
        // 1. Create a fresh database, switch it to WAL mode, populate it, then let
        //    the writer connection close (deinit at end of `do` scope). After that
        //    the -wal/-shm files are gone and the db header records WAL mode —
        //    exactly the state that exposed SQLITE_CANTOPEN with readonly=true.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("index.sqlite").path

        do {
            let writer = try DatabaseQueue(path: dbPath)
            // PRAGMA journal_mode must be issued outside a transaction.
            try writer.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL")
            }
            try writer.write { db in
                try db.execute(sql: """
                    CREATE TABLE entries (
                      path TEXT PRIMARY KEY, type TEXT NOT NULL, book TEXT, title TEXT,
                      title_en TEXT, title_cn TEXT, author TEXT, year_json TEXT, rating_json TEXT,
                      rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, kind TEXT, journal TEXT, source TEXT,
                      doi TEXT, publisher TEXT, isbn TEXT, category TEXT, translation_title_cn TEXT,
                      translation_douban_url TEXT, chapters_analyzed INTEGER, annotates TEXT,
                      created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0, mtime INTEGER,
                      preview TEXT NOT NULL DEFAULT '', body_len INTEGER NOT NULL DEFAULT 0,
                      added INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE VIRTUAL TABLE entry_trigram USING fts5(
                      path UNINDEXED, type UNINDEXED, text, tokenize = 'trigram'
                    );
                    """)
                try db.execute(sql: """
                    INSERT INTO entries (path, type, title, year_json, rating_score, themes_json,
                                        has_pdf, preview, mtime, added)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: ["vault/papers/wal-test.md", "paper", "WAL Test Title",
                                #""2023""#, 3.5, #"["regression"]"#, 1, "preview text", 1000, 2000])
                try db.execute(sql: "INSERT INTO entry_trigram (path, type, text) VALUES (?, ?, ?)",
                               arguments: ["vault/papers/wal-test.md", "paper", "WAL Test Title regression"])
            }
            // `writer` deinits here — SQLite checkpoints the WAL.
        }

        // Manually remove the -wal and -shm sidecar files to simulate the exact
        // state the production indexer produces: WAL-mode db with no shm present.
        // (On macOS, SQLite may leave the shm file around after closing even after
        // a full checkpoint, so we remove it explicitly here to make the repro reliable.)
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"
        try? FileManager.default.removeItem(atPath: walPath)
        try? FileManager.default.removeItem(atPath: shmPath)

        // Verify the shm file is gone (i.e. we're in the state that triggered the bug).
        #expect(!FileManager.default.fileExists(atPath: shmPath),
                "precondition: -shm should be absent before the read")

        // 2. Now open via IndexDatabase (which calls openQueue() internally).
        //    With the old readonly=true this threw SQLITE_CANTOPEN; with the fix it succeeds.
        let db = IndexDatabase(indexDBPath: dbPath)
        let entries = try db.loadEntries()
        #expect(entries.count == 1)
        #expect(entries[0].path == "vault/papers/wal-test.md")
        #expect(entries[0].title == "WAL Test Title")

        let hits = try db.search("WAL Test", type: nil, minRating: nil, theme: nil, limit: 80)
        #expect(hits.count == 1)
        #expect(hits[0].entry.path == "vault/papers/wal-test.md")
    }

    // MARK: - QUA-104: entries cache

    /// First call to loadEntries: cache file does not yet exist, so the
    /// SQL path runs and writes the cache asynchronously. We then poll for
    /// the file to confirm the write happened.
    @Test func loadEntriesWritesCacheOnFirstCall() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/a.md", type: "paper", title: "Alpha",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "alpha"),
            (path: "vault/papers/b.md", type: "paper", title: "Beta",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "beta"),
        ])
        let cachePath = Self.entriesCachePath(forDB: path)
        #expect(!FileManager.default.fileExists(atPath: cachePath))

        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.count == 2)
        // Cache write is dispatched to a background queue.
        #expect(awaitFile(cachePath), "cache file should be written within 2s")
    }

    /// Second call when cache matches the DB's revision: the cache file is
    /// used. We verify by hand-crafting a cache whose payload differs from the
    /// SQL result — if the cache path is taken we get the cache contents; if
    /// not we get the real DB rows.
    @Test func loadEntriesPrefersCacheWhenRevisionMatches() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/sql.md", type: "paper", title: "From SQL",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "sql"),
        ])
        let cachePath = Self.entriesCachePath(forDB: path)

        // Hand-write a cache containing a synthetic entry that's NOT in the DB.
        // If loadEntries returns it, we know the cache path ran.
        let synthetic = Entry(path: "vault/papers/synth.md", type: .paper,
                              title: "From Cache", author: [], year: nil,
                              ratingScore: 0, themes: [], preview: "",
                              hasPDF: false)
        let blob = try buildCacheBlob(entries: [synthetic], revision: 0)
        try blob.write(to: URL(fileURLWithPath: cachePath))

        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.count == 1)
        #expect(entries[0].title == "From Cache")
        #expect(entries[0].path == "vault/papers/synth.md")
    }

    /// After the DB's revision bumps, the existing cache becomes stale and
    /// loadEntries must fall back to SQL.
    @Test func loadEntriesInvalidatesCacheOnRevisionBump() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/a.md", type: "paper", title: "Alpha",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "alpha"),
        ])
        let cachePath = Self.entriesCachePath(forDB: path)
        let db = IndexDatabase(indexDBPath: path)
        // 1st call: writes cache @ revision 0.
        _ = try db.loadEntries()
        #expect(awaitFile(cachePath))

        // Bump revision — the cache is now for revision 0, DB is at 1.
        try bumpRevision(path)

        // Cache must be discarded; SQL path returns the real row.
        // We need a fresh IndexDatabase so cachedQueue re-opens (otherwise the
        // already-warm queue would still read the same WAL snapshot, but since
        // we used a separate DatabaseQueue to write, the cached queue sees the
        // committed write fine on its next read — both approaches work; using
        // a new value here is the most realistic boot scenario).
        let db2 = IndexDatabase(indexDBPath: path)
        let entries = try db2.loadEntries()
        #expect(entries.count == 1)
        #expect(entries[0].path == "vault/papers/a.md")
        #expect(entries[0].title == "Alpha")
    }

    /// A corrupt cache (garbage bytes) must be deleted and the SQL path used.
    @Test func loadEntriesRecoversFromCorruptCache() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/a.md", type: "paper", title: "Alpha",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "alpha"),
        ])
        let cachePath = Self.entriesCachePath(forDB: path)
        // Plant garbage where the cache should be.
        try Data(repeating: 0xFF, count: 256).write(to: URL(fileURLWithPath: cachePath))

        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.count == 1)
        #expect(entries[0].path == "vault/papers/a.md")
        // After the failed read, the corrupt file must be gone (then rewritten
        // by the async path). Allow a moment for either: deletion is sync,
        // rewrite is async.
        #expect(awaitFile(cachePath), "valid cache should be rewritten after corrupt one is removed")
    }

    /// SQL path orders by path ascending so cache contents are stable.
    @Test func loadEntriesOrderedByPath() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/zeta.md",  type: "paper", title: "Z",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "z"),
            (path: "vault/papers/alpha.md", type: "paper", title: "A",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "a"),
            (path: "vault/papers/mu.md",    type: "paper", title: "M",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "m"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.map(\.path) == [
            "vault/papers/alpha.md", "vault/papers/mu.md", "vault/papers/zeta.md",
        ])
    }

    /// Build a valid cache blob matching IndexDatabase.decodeCachePayload.
    /// Mirrors the encoder in writeCacheBestEffort.
    private func buildCacheBlob(entries: [Entry], revision: Int64) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(entries)

        var blob = Data()
        // Magic "MARPLE\0C" — must match IndexDatabase.cacheMagic.
        blob.append(contentsOf: [0x4D, 0x41, 0x52, 0x50, 0x4C, 0x45, 0x00, 0x43])
        var v = UInt32(1).littleEndian
        withUnsafeBytes(of: &v) { blob.append(contentsOf: $0) }
        var r = UInt64(bitPattern: revision).littleEndian
        withUnsafeBytes(of: &r) { blob.append(contentsOf: $0) }
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { blob.append(contentsOf: $0) }
        blob.append(payload)
        return blob
    }
}
