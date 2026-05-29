import Testing
import Foundation
import GRDB
@testable import MarpleKit

// MARK: - IndexWriter tests
//
// TDD: this file is written BEFORE IndexWriter.swift is implemented.
// It verifies the full schema+insert round-trip against IndexDatabase's read path,
// plus direct SQL assertions on entry_themes, entry_text, entry_search, and
// the fts_json flattening behaviour.

@Suite("IndexWriter")
struct IndexWriterTests {

    // MARK: - Helpers

    /// Create a temp directory + empty DB path (file doesn't exist yet).
    private func tempDBPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.sqlite").path
    }

    /// Open (or create) a DatabaseQueue at the given path and run createSchema.
    private func openAndCreateSchema(at path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try IndexWriter.createSchema(db)
        }
        return queue
    }

    // MARK: - Fixture entries

    /// A paper entry with themes, year array, author, rating, preview.
    private func makePaperEntry() -> IndexedEntry {
        IndexedEntry(
            path: "vault/papers/smith-dogs-2019.md",
            entryType: "paper",
            book: nil,
            title: "Dogs and Their Owners",
            titleEn: "Dogs and Their Owners",
            titleCn: nil,
            author: ["Smith, John"],
            yearJSON: "2019",           // numeric scalar → "2019"
            ratingJSON: "\"★★★\"",
            ratingScore: 3.0,
            themes: ["animal-behaviour", "psychology"],
            topics: ["canine-cognition"],
            source: "Journal of Dogs",
            doi: "10.1234/dogs.2019",
            publisher: nil,
            isbn: nil,
            translationTitleCn: nil,
            translationDoubanURL: nil,
            chaptersAnalyzed: nil,
            annotates: nil,
            created: "2019-01-01",
            pdfSlug: "smith-dogs-2019",
            hasPDF: true,
            mtime: 1_700_000_000_000,
            preview: "Dogs are fascinating creatures that form strong bonds.",
            bodyLen: 500,
            added: 1_600_000_000_000,
            bodyText: "Dogs are fascinating creatures that form strong bonds with their owners.",
            searchText: "vault/papers/smith-dogs-2019.md\nDogs and Their Owners\nDogs and Their Owners\n\nSmith, John\n\n\n\nDogs are fascinating creatures that form strong bonds with their owners."
        )
    }

    /// A book with CJK title, year stored as JSON array, no PDF.
    private func makeBookEntry() -> IndexedEntry {
        // year_json = "[2010,2015]" — a JSON array; fts_json should flatten to "2010 2015"
        IndexedEntry(
            path: "vault/books/tanaka-cat-2010/overview.md",
            entryType: "book",
            book: nil,
            title: "猫の哲学",
            titleEn: "Philosophy of Cats",
            titleCn: "猫的哲学",
            author: ["Tanaka, Yuki"],
            yearJSON: "[2010,2015]",
            ratingJSON: nil,
            ratingScore: 0.0,
            themes: ["philosophy", "animals"],
            topics: nil,
            source: nil,
            doi: nil,
            publisher: "Kyoto Press",
            isbn: "978-4-1234",
            translationTitleCn: "猫の哲学（中文版）",
            translationDoubanURL: "https://book.douban.com/subject/12345/",
            chaptersAnalyzed: 5,
            annotates: nil,
            created: nil,
            pdfSlug: nil,
            hasPDF: false,
            mtime: 1_650_000_000_000,
            preview: "猫は謎めいた生き物である。",
            bodyLen: 800,
            added: 0,
            bodyText: "猫は謎めいた生き物である。哲学的な問いが自然と湧いてくる。",
            searchText: "vault/books/tanaka-cat-2010/overview.md\n猫の哲学\nPhilosophy of Cats\n猫的哲学\nTanaka, Yuki\nKyoto Press\n978-4-1234\n猫の哲学（中文版）\n猫は謎めいた生き物である。哲学的な問いが自然と湧いてくる。"
        )
    }

    /// A note entry with no themes.
    private func makeNoteEntry() -> IndexedEntry {
        IndexedEntry(
            path: "vault/notes/quick-note.md",
            entryType: "note",
            book: nil,
            title: "Quick Note on Cats",
            titleEn: nil,
            titleCn: nil,
            author: [],
            yearJSON: nil,
            ratingJSON: nil,
            ratingScore: 0.0,
            themes: nil,
            topics: nil,
            source: nil,
            doi: nil,
            publisher: nil,
            isbn: nil,
            translationTitleCn: nil,
            translationDoubanURL: nil,
            chaptersAnalyzed: nil,
            annotates: nil,
            created: nil,
            pdfSlug: nil,
            hasPDF: false,
            mtime: nil,
            preview: "",
            bodyLen: 0,
            added: 0,
            bodyText: "",
            searchText: "vault/notes/quick-note.md\nQuick Note on Cats"
        )
    }

    // MARK: - Schema creation

    @Test("createSchema creates the surviving tables and drops the retired ones")
    func createSchemaAllTables() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        try queue.read { db in
            #expect(try db.tableExists("entries"))
            #expect(try db.tableExists("entry_themes"))
            #expect(try db.tableExists("meta"))
            // entry_trigram is an FTS5 virtual table — visible in sqlite_master.
            let fts = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' AND name = 'entry_trigram'")
            #expect(fts == ["entry_trigram"])
            // QUA-102: entry_search / entry_text are write-only legacy tables
            // that no Swift read path queries. createSchema must NOT create them.
            #expect(try !db.tableExists("entry_search"))
            #expect(try !db.tableExists("entry_text"))
        }
    }

    @Test("createSchema is idempotent (DROP IF EXISTS + re-CREATE)")
    func createSchemaIdempotent() throws {
        let path = try tempDBPath()
        // First creation
        let queue = try openAndCreateSchema(at: path)
        // Second creation should not throw (DROP IF EXISTS guard)
        try queue.write { db in
            try IndexWriter.createSchema(db)
        }
        // Verify entries table still exists after second schema creation
        let tableExists = try queue.read { db in
            try db.tableExists("entries")
        }
        #expect(tableExists)
    }

    @Test("createSchema creates the 4 indexes")
    func createSchemaIndexes() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        try queue.read { db in
            let indexes = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='index' AND name IN (
                  'entries_type_rating_title_idx',
                  'entries_annotates_idx',
                  'entries_mtime_idx',
                  'entry_themes_theme_idx'
                )
                ORDER BY name
                """)
            #expect(indexes.sorted() == [
                "entries_annotates_idx",
                "entries_mtime_idx",
                "entries_type_rating_title_idx",
                "entry_themes_theme_idx",
            ])
        }
    }

    // MARK: - Insert + loadEntries round-trip

    @Test("insert paper entry + loadEntries round-trip")
    func insertPaperEntryRoundTrip() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        let entry = makePaperEntry()
        try queue.write { db in try IndexWriter.insert(db, entry) }

        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.path == "vault/papers/smith-dogs-2019.md")
        #expect(e.type == .paper)
        #expect(e.title == "Dogs and Their Owners")
        // SQLite round-trip is lossless: the author column stores a JSON
        // array, so single authors with commas in their names (e.g. "Smith,
        // John" in Last-First form) round-trip exactly.
        #expect(e.author == ["Smith, John"])
        #expect(e.year == "2019")
        #expect(e.ratingScore == 3.0)
        #expect(e.hasPDF == true)
        #expect(e.mtime == 1_700_000_000_000)
        #expect(e.added == 1_600_000_000_000)
        #expect(e.preview == "Dogs are fascinating creatures that form strong bonds.")
        #expect(e.themes.sorted() == ["animal-behaviour", "psychology"])
        // QUA-137: topics round-trip through the topics_json column like themes.
        #expect(e.topics == ["canine-cognition"])
    }

    @Test("topics frontmatter participates in persisted search")
    func topicsFrontmatterSearchableThroughTrigram() throws {
        let text = """
        ---
        type: paper
        title: Unrelated Title
        topics:
          - canine-cognition
        ---

        Neutral body.
        """
        let outcome = buildIndexedEntry(
            text: text,
            rel: "vault/papers/topic-only.md",
            fileStem: "topic-only",
            sourceSlugs: [],
            mtimeMs: nil
        )
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected indexed entry, got \(outcome)")
            return
        }

        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        try queue.write { db in try IndexWriter.insert(db, entry) }

        let db = IndexDatabase(indexDBPath: path)
        let hits = try db.search("canine-cognition", type: nil, minRating: nil, theme: nil, limit: 80)
        #expect(hits.map(\.entry.path) == ["vault/papers/topic-only.md"])
    }

    /// QUA-109: SQLite author column is JSON-encoded so round-trips preserve
    /// identity even when individual names contain commas. The earlier
    /// joined-string scheme would have split "Smith, John Jr." into two names.
    @Test("author JSON round-trip preserves comma-in-name identity")
    func authorRoundTripLossless() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        let entry = IndexedEntry(
            path: "vault/papers/smith-jr-2020.md",
            entryType: "paper", book: nil,
            title: "Test", titleEn: nil, titleCn: nil,
            author: ["Smith, John Jr.", "Jane Doe"],
            yearJSON: "2020", ratingJSON: nil, ratingScore: 0,
            themes: nil, topics: nil, source: nil, doi: nil,
            publisher: nil, isbn: nil,
            translationTitleCn: nil, translationDoubanURL: nil,
            chaptersAnalyzed: nil, annotates: nil, created: nil,
            pdfSlug: nil, hasPDF: false, mtime: nil,
            preview: "", bodyLen: 0, added: 0,
            bodyText: "", searchText: "test"
        )
        try queue.write { db in try IndexWriter.insert(db, entry) }
        let db = IndexDatabase(indexDBPath: path)
        let loaded = try db.loadEntries()
        #expect(loaded.count == 1)
        #expect(loaded[0].author == ["Smith, John Jr.", "Jane Doe"])
    }

    /// Legacy DBs (built before QUA-109) stored author as a joined string.
    /// The decoder must still accept that shape so reindex doesn't break on
    /// first-run upgrade.
    @Test("loadEntries tolerates legacy joined-string author column")
    func legacyAuthorColumnReadsBack() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        try queue.write { db in
            try IndexWriter.insert(db, makePaperEntry())
            // Simulate a pre-QUA-109 row by overwriting with the joined form.
            try db.execute(sql: "UPDATE entries SET author = ?",
                           arguments: ["Sara Ahmed, John Doe"])
        }
        let db = IndexDatabase(indexDBPath: path)
        let loaded = try db.loadEntries()
        #expect(loaded.count == 1)
        #expect(loaded[0].author == ["Sara Ahmed", "John Doe"])
    }

    @Test("insert book entry + loadEntries maps all fields")
    func insertBookEntryRoundTrip() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        let entry = makeBookEntry()
        try queue.write { db in try IndexWriter.insert(db, entry) }

        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.path == "vault/books/tanaka-cat-2010/overview.md")
        #expect(e.type == .book)
        #expect(e.title == "猫の哲学")
        #expect(e.ratingScore == 0.0)
        #expect(e.hasPDF == false)
        #expect(e.themes.sorted() == ["animals", "philosophy"])
    }

    @Test("insert multiple entries, loadEntries returns all")
    func insertMultipleEntries() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        let paper = makePaperEntry()
        let book = makeBookEntry()
        let note = makeNoteEntry()
        try queue.write { db in
            try IndexWriter.insert(db, paper)
            try IndexWriter.insert(db, book)
            try IndexWriter.insert(db, note)
        }

        let db = IndexDatabase(indexDBPath: path)
        let entries = try db.loadEntries()
        #expect(entries.count == 3)
        let paths = entries.map(\.path).sorted()
        #expect(paths == [
            "vault/books/tanaka-cat-2010/overview.md",
            "vault/notes/quick-note.md",
            "vault/papers/smith-dogs-2019.md",
        ])
    }

    // MARK: - entry_themes table

    @Test("entry_themes has one row per non-empty theme")
    func entryThemesRows() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        let entry = makePaperEntry()
        try queue.write { db in try IndexWriter.insert(db, entry) }

        try queue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT path, theme, type FROM entry_themes WHERE path = ? ORDER BY theme",
                arguments: [entry.path])
            #expect(rows.count == 2)
            let themes: [String] = rows.map { $0["theme"] }
            #expect(themes == ["animal-behaviour", "psychology"])
            let types: [String] = rows.map { $0["type"] }
            #expect(types == ["paper", "paper"])
        }
    }

    @Test("entry_themes is empty when themes is nil")
    func entryThemesEmptyForNilThemes() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        let note = makeNoteEntry()
        try queue.write { db in try IndexWriter.insert(db, note) }

        try queue.read { db in
            let count = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM entry_themes WHERE path = ?",
                arguments: [note.path])!
            #expect(count == 0)
        }
    }

    // MARK: - entry_trigram FTS

    @Test("entry_trigram text equals searchText (same as entry_text.search_text)")
    func entryTrigramTextEqualsSearchText() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        let entry = makePaperEntry()
        try queue.write { db in try IndexWriter.insert(db, entry) }

        try queue.read { db in
            // entry_trigram stores search_text, so this FTS MATCH on a
            // body substring should hit exactly that entry.
            let rows = try Row.fetchAll(db, sql:
                "SELECT path FROM entry_trigram WHERE entry_trigram MATCH ?",
                arguments: ["\"fascinating\""])
            #expect(rows.count == 1)
            let p: String = rows[0]["path"]
            #expect(p == entry.path)
        }
    }

    @Test("search() finds entry via CJK trigram")
    func searchFindsCJKTrigram() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        let book = makeBookEntry()
        try queue.write { db in try IndexWriter.insert(db, book) }

        let idb = IndexDatabase(indexDBPath: path)
        // "謎めいた" is 4 chars (≥3), should hit trigram FTS
        let hits = try idb.search("謎めいた", type: nil, minRating: nil, theme: nil, limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].entry.path == book.path)
    }

    // MARK: - entries columns (has_pdf stored as 0/1)

    @Test("has_pdf stored as 1 for true, 0 for false")
    func hasPDFIntegerStorage() throws {
        let path = try tempDBPath()
        let queue = try openAndCreateSchema(at: path)
        try queue.write { db in
            try IndexWriter.insert(db, makePaperEntry())   // hasPDF = true
            try IndexWriter.insert(db, makeBookEntry())    // hasPDF = false
        }

        try queue.read { db in
            let paperPDF = try Int.fetchOne(db, sql:
                "SELECT has_pdf FROM entries WHERE path = ?",
                arguments: ["vault/papers/smith-dogs-2019.md"])!
            #expect(paperPDF == 1)

            let bookPDF = try Int.fetchOne(db, sql:
                "SELECT has_pdf FROM entries WHERE path = ?",
                arguments: ["vault/books/tanaka-cat-2010/overview.md"])!
            #expect(bookPDF == 0)
        }
    }

}
