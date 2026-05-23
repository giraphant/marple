import Foundation
import GRDB

// MARK: - IndexWriter
//
// GRDB schema DDL + insert helpers for the Marple index database.
//
// Mirrors the following sections of `rust/reader-core/src/indexer.rs`:
//   - Schema DDL block (:1162-1257) — DROP IF EXISTS + CREATE TABLE/VIRTUAL TABLE + 4 indexes + meta
//   - `insert_indexed_entry` (:1286-1382) — entries + entry_text + entry_themes + entry_search + entry_trigram
//   - `fts_json` (:1115-1136) — recursive JSON → space-separated leaves
//   - `json_cell` / `fieldJSONCell` — already ported in IndexFields.swift; re-used here
//
// THIS IS A PORT — every column list, value expression, and table definition
// must match the Rust source exactly.

public enum IndexWriter {

    // MARK: - createSchema

    /// Create the full index schema on an open GRDB `Database`.
    ///
    /// Mirrors `write_sqlite_index` (:1162-1257) in indexer.rs:
    /// - DROP IF EXISTS for every table (idempotent; safe to call twice)
    /// - CREATE TABLE entries (27 columns, exact DDL match)
    /// - CREATE TABLE entry_text
    /// - CREATE TABLE entry_themes
    /// - CREATE VIRTUAL TABLE entry_search USING fts5
    /// - CREATE VIRTUAL TABLE entry_trigram USING fts5(tokenize='trigram')
    /// - CREATE TABLE meta
    /// - 4 indexes: entries_type_rating_title_idx, entries_annotates_idx,
    ///              entries_mtime_idx, entry_themes_theme_idx
    public static func createSchema(_ db: Database) throws {
        // Match the Rust DDL verbatim (including DROP order and column list).
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
              source TEXT,
              doi TEXT,
              publisher TEXT,
              isbn TEXT,
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

            CREATE TABLE entry_text (
              path TEXT PRIMARY KEY,
              search_text TEXT NOT NULL,
              FOREIGN KEY (path) REFERENCES entries(path) ON DELETE CASCADE
            );

            CREATE TABLE entry_themes (
              path TEXT NOT NULL,
              theme TEXT NOT NULL,
              type TEXT NOT NULL,
              PRIMARY KEY (path, theme),
              FOREIGN KEY (path) REFERENCES entries(path) ON DELETE CASCADE
            );

            CREATE VIRTUAL TABLE entry_search USING fts5(
              path UNINDEXED,
              type UNINDEXED,
              title,
              author,
              book,
              themes,
              topic,
              source,
              year,
              preview,
              doi,
              body
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
            """)
    }

    // MARK: - insert

    /// Insert one entry's rows across entries + entry_text + entry_themes +
    /// entry_search + entry_trigram.
    ///
    /// Mirrors `insert_indexed_entry` (:1286-1382) in indexer.rs.
    ///
    /// Column order and value derivation must match the Rust source exactly:
    /// - `themes_json`          = serde_json of themes array (compact) or NULL
    /// - `has_pdf`              = 1 / 0
    /// - `year_json`/`rating_json` = the already-built JSON strings (or NULL)
    /// - `entry_text.search_text` = entry.searchText
    /// - `entry_themes`         = one row per non-empty theme → (path, theme, type)
    /// - `entry_search.title`   = searchText([title,titleEn,titleCn,translationTitleCn])
    /// - `entry_search.themes`  = themes.joined(" ")
    /// - `entry_search.year`    = ftsJSON(yearJSON) — recursively flattened JSON leaves
    /// - `entry_search.body`    = entry.bodyText
    /// - `entry_trigram.text`   = entry.searchText (SAME as entry_text.search_text)
    public static func insert(_ db: Database, _ entry: IndexedEntry) throws {
        // --- entries ---
        let themesJSONStr: String? = entry.themes.map { themes in
            // serde_json::to_string of a String array → compact JSON array
            "[" + themes.map { jsonEncodeStringLiteral($0) }.joined(separator: ",") + "]"
        }

        try db.execute(
            sql: """
                INSERT INTO entries (
                  path, type, book, title, title_en, title_cn, author, year_json, rating_json,
                  rating_score, themes_json, topic, source, doi, publisher, isbn,
                  translation_title_cn, translation_douban_url, chapters_analyzed,
                  annotates, created, pdf_slug, has_pdf, mtime, preview, body_len, added
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                entry.path,
                entry.entryType,
                entry.book,
                entry.title,
                entry.titleEn,
                entry.titleCn,
                entry.author,
                entry.yearJSON,         // already-built JSON string or nil
                entry.ratingJSON,       // already-built JSON string or nil
                entry.ratingScore,
                themesJSONStr,
                entry.topic,
                entry.source,
                entry.doi,
                entry.publisher,
                entry.isbn,
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
        // Mirrors: for theme in themes { if !theme.is_empty() { insert } }
        if let themes = entry.themes {
            for theme in themes where !theme.isEmpty {
                try db.execute(
                    sql: "INSERT INTO entry_themes (path, theme, type) VALUES (?, ?, ?)",
                    arguments: [entry.path, theme, entry.entryType]
                )
            }
        }

        // --- entry_text ---
        // search_text is the composite searchText string.
        try db.execute(
            sql: "INSERT INTO entry_text (path, search_text) VALUES (?, ?)",
            arguments: [entry.path, entry.searchText]
        )

        // --- entry_search ---
        // title = searchText([title, titleEn, titleCn, translationTitleCn])
        // Mirrors: fts_title = search_text(&[title, title_en, title_cn, translation_title_cn])
        let ftsTitle = searchText([
            entry.title ?? "",
            entry.titleEn ?? "",
            entry.titleCn ?? "",
            entry.translationTitleCn ?? "",
        ])

        // themes = themes joined " " (nil → nil/NULL)
        let ftsThemes: String? = entry.themes.map { $0.joined(separator: " ") }

        // year = fts_json(year_json) — flatten JSON to space-separated leaf values
        let ftsYear: String = ftsJSON(entry.yearJSON)

        try db.execute(
            sql: """
                INSERT INTO entry_search (
                  path, type, title, author, book, themes, topic, source, year,
                  preview, doi, body
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                entry.path,
                entry.entryType,
                ftsTitle,
                entry.author,
                entry.book,
                ftsThemes,
                entry.topic,
                entry.source,
                ftsYear,
                entry.preview,
                entry.doi,
                entry.bodyText,
            ]
        )

        // --- entry_trigram ---
        // text = entry.searchText — SAME string as entry_text.search_text
        try db.execute(
            sql: "INSERT INTO entry_trigram (path, type, text) VALUES (?, ?, ?)",
            arguments: [entry.path, entry.entryType, entry.searchText]
        )
    }

    // MARK: - fts_json

    /// Flatten a JSON string to a space-separated string of leaf scalar values.
    ///
    /// Mirrors `fts_json` (:1115-1136) in indexer.rs:
    ///   - Null     → skip
    ///   - String   → push the string
    ///   - Number   → push its string representation
    ///   - Bool     → push "true" / "false"
    ///   - Array    → recurse into each item
    ///   - Object   → push the JSON string of the object
    ///
    /// Input is the raw `year_json` column text (e.g. `"2019"`, `"[2010,2015]"`,
    /// `"\"2019\""`, nil). Returns `""` when input is nil or empty.
    static func ftsJSON(_ jsonString: String?) -> String {
        guard let jsonString, !jsonString.isEmpty else { return "" }
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            // Unparseable — return the raw string as-is (best-effort)
            return jsonString
        }
        var out: [String] = []
        collectLeaves(parsed, into: &out)
        return out.joined(separator: " ")
    }

    // MARK: - Private helpers

    /// Recursively collect leaf scalars from a JSON value.
    /// Mirrors the inner `collect` closure in `fts_json`.
    private static func collectLeaves(_ value: Any, into out: inout [String]) {
        switch value {
        case is NSNull:
            break   // Null → skip
        case let s as String:
            out.append(s)
        case let n as NSNumber:
            // NSNumber wraps both Bool and numeric types.
            // Distinguish Bool (ObjC type encoding 'c' for signed char = Bool in Cocoa).
            let typeCode = String(cString: n.objCType)
            if typeCode == "c" {
                // Bool
                out.append(n.boolValue ? "true" : "false")
            } else if n.doubleValue == Double(n.intValue) && !n.stringValue.contains(".") {
                // Integer-valued number
                out.append(String(n.intValue))
            } else {
                out.append(n.stringValue)
            }
        case let arr as [Any]:
            for item in arr {
                collectLeaves(item, into: &out)
            }
        case let obj as [String: Any]:
            // Object → push the JSON serialization of the entire object
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                out.append(s)
            }
        default:
            break
        }
    }

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
