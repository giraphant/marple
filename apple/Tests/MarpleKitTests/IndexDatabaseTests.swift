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
                  rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, source TEXT,
                  doi TEXT, publisher TEXT, isbn TEXT, translation_title_cn TEXT,
                  translation_douban_url TEXT, chapters_analyzed INTEGER, annotates TEXT,
                  created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0, mtime INTEGER,
                  preview TEXT NOT NULL DEFAULT '', body_len INTEGER NOT NULL DEFAULT 0,
                  added INTEGER NOT NULL DEFAULT 0
                );
                CREATE VIRTUAL TABLE entry_trigram USING fts5(
                  path UNINDEXED, type UNINDEXED, text, tokenize = 'trigram'
                );
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

    @Test func loadEntriesMapsColumns() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/a.md", type: "paper-analysis", title: "Alpha",
             themesJSON: #"["x","y"]"#, yearJSON: #""2014""#, hasPDF: 1, rating: 4.0, text: "alpha body"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.path == "vault/papers/a.md")
        #expect(e.type == .paperAnalysis)
        #expect(e.title == "Alpha")
        #expect(e.themes == ["x", "y"])
        #expect(e.year == "2014")
        #expect(e.hasPDF == true)
        #expect(e.ratingScore == 4.0)
    }

    @Test func loadEntriesReturnsEmptyWhenDBMissing() throws {
        let db = IndexDatabase(indexDBPath: "/nonexistent/index.sqlite")
        #expect(try db.loadEntries() == [])
    }

    @Test func searchMatchesChineseSubstring() throws {
        let path = try makeFixtureDB([
            (path: "vault/papers/cn.md", type: "paper-analysis", title: "量表",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "拨号量表与感官"),
            (path: "vault/papers/en.md", type: "paper-analysis", title: "Dial",
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
            (path: "vault/papers/under.md", type: "paper-analysis", title: "Under",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "has a _ underscore"),
            (path: "vault/papers/plain.md", type: "paper-analysis", title: "Plain",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "no special chars here"),
            (path: "vault/papers/pct.md", type: "paper-analysis", title: "Pct",
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
            (path: "vault/papers/p.md", type: "paper-analysis", title: "P",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "shared keyword"),
            (path: "vault/notes/n.md", type: "note", title: "N",
             themesJSON: nil, yearJSON: nil, hasPDF: 0, rating: 0, text: "shared keyword"),
        ])
        let db = IndexDatabase(indexDBPath: path)
        let onlyPapers = try db.search("shared", type: .paperAnalysis, minRating: nil, theme: nil, limit: 80)
        #expect(onlyPapers.map(\.entry.path) == ["vault/papers/p.md"])
        let limited = try db.search("shared", type: nil, minRating: nil, theme: nil, limit: 1)
        #expect(limited.count == 1)
    }
}
