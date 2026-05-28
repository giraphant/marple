import Foundation
import GRDB

// MARK: - IndexWriter
//
// GRDB schema DDL + insert helpers for the Marple index database.
//
// QUA-102: the Rust port previously also wrote `entry_text` (mirror of the
// composite search text) and `entry_search` (12-column FTS5 over title /
// author / body / etc.). Both turned out to be write-only in the Swift app —
// `IndexDatabase.search()` only queries `entry_trigram`. Together they were
// ~660 MB on a 1.4 GB index, so they were dropped. Old DBs are detected by
// `VaultIndexer.indexSchemaCurrent()` (it returns false when `entry_search`
// still exists) and rebuilt via `buildFull` on next boot.

public enum IndexWriter {

    // MARK: - createSchema

    /// Create the full index schema on an open GRDB `Database`.
    ///
    /// - DROP IF EXISTS for every table this writer creates (idempotent;
    ///   safe to call twice) PLUS `entry_search`/`entry_text` so any older
    ///   DB that happens to be opened directly is also stripped.
    /// - CREATE TABLE entries (27 columns)
    /// - CREATE TABLE entry_themes
    /// - CREATE VIRTUAL TABLE entry_trigram USING fts5(tokenize='trigram')
    /// - CREATE TABLE meta
    /// - 4 indexes: entries_type_rating_title_idx, entries_annotates_idx,
    ///              entries_mtime_idx, entry_themes_theme_idx
    public static func createSchema(_ db: Database) throws {
        // PRAGMA journal_mode / synchronous are NOT set here — those are
        // bulk-build optimisations applied at the DatabaseQueue level by VaultIndexer.
        try db.execute(sql: """
            DROP TABLE IF EXISTS entries;
            DROP TABLE IF EXISTS entry_themes;
            DROP TABLE IF EXISTS entry_search;
            DROP TABLE IF EXISTS entry_text;
            DROP TABLE IF EXISTS entry_trigram;
            DROP TABLE IF EXISTS meta;
            DROP TABLE IF EXISTS entry_vectors;
            DROP TABLE IF EXISTS entry_vectors_staging;

            CREATE TABLE entries (
              path TEXT PRIMARY KEY,
              type TEXT NOT NULL,
              book TEXT,
              title TEXT,
              title_en TEXT,
              title_cn TEXT,
              author TEXT,
              year_json TEXT,
              rating_json TEXT,
              rating_score REAL NOT NULL DEFAULT 0,
              themes_json TEXT,
              topic TEXT,
              kind TEXT,
              journal TEXT,
              source TEXT,
              doi TEXT,
              publisher TEXT,
              isbn TEXT,
              category TEXT,
              translation_title_cn TEXT,
              translation_douban_url TEXT,
              chapters_analyzed INTEGER,
              annotates TEXT,
              created TEXT,
              pdf_slug TEXT,
              has_pdf INTEGER NOT NULL DEFAULT 0,
              mtime INTEGER,
              preview TEXT NOT NULL DEFAULT '',
              body_len INTEGER NOT NULL DEFAULT 0,
              added INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE entry_themes (
              path TEXT NOT NULL,
              theme TEXT NOT NULL,
              type TEXT NOT NULL,
              PRIMARY KEY (path, theme),
              FOREIGN KEY (path) REFERENCES entries(path) ON DELETE CASCADE
            );

            CREATE VIRTUAL TABLE entry_trigram USING fts5(
              path UNINDEXED,
              type UNINDEXED,
              text,
              tokenize = 'trigram'
            );

            CREATE TABLE meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );

            CREATE INDEX entries_type_rating_title_idx
              ON entries(type, rating_score DESC, title COLLATE NOCASE);
            CREATE INDEX entries_annotates_idx ON entries(annotates);
            CREATE INDEX entries_mtime_idx ON entries(mtime DESC);
            CREATE INDEX entry_themes_theme_idx ON entry_themes(theme, type);

            INSERT INTO meta(key, value) VALUES ('entries_revision', '0');
            """)
    }

    // MARK: - bumpEntriesRevision

    /// Increment `meta.entries_revision` to invalidate any on-disk cache
    /// (.marple/entries.cache) that snapshotted a previous state of the
    /// `entries` table. Called by VaultIndexer at the end of any write that
    /// mutates entries — buildFull and reconcile-with-changes.
    ///
    /// Stored as text (SQLite has no native bigint), parsed/incremented in app
    /// code so we don't depend on a SQLite UPDATE-with-expression that could
    /// race with a concurrent reader. The mutation runs inside the caller's
    /// transaction so it is atomic with the data write.
    public static func bumpEntriesRevision(_ db: Database) throws {
        let current = (try String.fetchOne(db, sql:
            "SELECT value FROM meta WHERE key = 'entries_revision'")
            .flatMap { Int64($0) }) ?? 0
        let next = current &+ 1
        try db.execute(
            sql: "INSERT OR REPLACE INTO meta(key, value) VALUES ('entries_revision', ?)",
            arguments: [String(next)]
        )
    }

    /// Read the current `meta.entries_revision`. Returns 0 when the key or the
    /// meta table is absent (e.g. very old DBs caught by indexSchemaCurrent
    /// before this path runs).
    public static func entriesRevision(_ db: Database) throws -> Int64 {
        guard try db.tableExists("meta") else { return 0 }
        let raw = try String.fetchOne(db, sql:
            "SELECT value FROM meta WHERE key = 'entries_revision'")
        return raw.flatMap { Int64($0) } ?? 0
    }

    // MARK: - insert

    /// Insert one entry's rows across entries + entry_themes + entry_trigram.
    ///
    /// Column derivation:
    /// - `themes_json`          = serde_json of themes array (compact) or NULL
    /// - `has_pdf`              = 1 / 0
    /// - `year_json`/`rating_json` = the already-built JSON strings (or NULL)
    /// - `entry_themes`         = one row per non-empty theme → (path, theme, type)
    /// - `entry_trigram.text`   = entry.searchText (composite of rel + titles
    ///                            + author + publisher + isbn + translationTitleCn + body)
    public static func insert(_ db: Database, _ entry: IndexedEntry) throws {
        // --- entries ---
        let themesJSONStr: String? = entry.themes.map { themes in
            // serde_json::to_string of a String array → compact JSON array
            "[" + themes.map { jsonEncodeStringLiteral($0) }.joined(separator: ",") + "]"
        }
        // Author column stores a JSON array (same shape as themes_json) so
        // round-trips are lossless even when individual names contain commas
        // (e.g. "Smith, John Jr." stays one author). The legacy joined-string
        // shape is still tolerated on read for back-compat with old caches.
        let authorJSONStr: String? = entry.author.isEmpty
            ? nil
            : "[" + entry.author.map { jsonEncodeStringLiteral($0) }.joined(separator: ",") + "]"

        try db.execute(
            sql: """
                INSERT INTO entries (
                  path, type, book, title, title_en, title_cn, author, year_json, rating_json,
                  rating_score, themes_json, topic, kind, journal, source, doi, publisher, isbn, category,
                  translation_title_cn, translation_douban_url, chapters_analyzed,
                  annotates, created, pdf_slug, has_pdf, mtime, preview, body_len, added
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                entry.path,
                entry.entryType,
                entry.book,
                entry.title,
                entry.titleEn,
                entry.titleCn,
                authorJSONStr,
                entry.yearJSON,         // already-built JSON string or nil
                entry.ratingJSON,       // already-built JSON string or nil
                entry.ratingScore,
                themesJSONStr,
                entry.topic,
                entry.kind,
                entry.journal,
                entry.source,
                entry.doi,
                entry.publisher,
                entry.isbn,
                entry.category,
                entry.translationTitleCn,
                entry.translationDoubanURL,
                entry.chaptersAnalyzed,
                entry.annotates,
                entry.created,
                entry.pdfSlug,
                entry.hasPDF ? 1 : 0,
                entry.mtime,
                entry.preview,
                entry.bodyLen,
                entry.added,
            ]
        )

        // --- entry_themes ---
        // One row per non-empty theme, carrying the entry's type.
        if let themes = entry.themes {
            for theme in themes where !theme.isEmpty {
                try db.execute(
                    sql: "INSERT INTO entry_themes (path, theme, type) VALUES (?, ?, ?)",
                    arguments: [entry.path, theme, entry.entryType]
                )
            }
        }

        // --- entry_trigram ---
        // text = entry.searchText (composite path + titles + author + body, etc.)
        try db.execute(
            sql: "INSERT INTO entry_trigram (path, type, text) VALUES (?, ?, ?)",
            arguments: [entry.path, entry.entryType, entry.searchText]
        )
    }

    // MARK: - Private helpers

    /// Encode a Swift String as a compact JSON string literal.
    /// Used for themes_json serialization (mirrors serde_json::to_string).
    private static func jsonEncodeStringLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1F:
                out += String(format: "\\u%04x", ch.value)
            default:
                out.unicodeScalars.append(ch)
            }
        }
        out += "\""
        return out
    }
}
