import Testing
import Foundation
import GRDB
@testable import MarpleKit

// MARK: - VaultIndexer tests
//
// TDD: written BEFORE VaultIndexer.swift is implemented.
// Tests cover:
//   - buildFull() builds a correct index and returns entry count
//   - reconcile() when index is missing performs a full build
//   - reconcile() diffs mtimes: upserts new + modified, deletes vanished
//   - second reconcile() with no changes → all unchanged
//   - dotfiles and .trash directories are excluded from the walk
//   - WAL mode is active on the live DB after buildFull()

@Suite("VaultIndexer")
struct VaultIndexerTests {

    // MARK: - Helpers

    /// Create a disposable workspace directory tree:
    ///   <tmp>/vault/
    ///   <tmp>/vault/papers/
    ///   <tmp>/vault/notes/
    ///   <tmp>/sources/          (empty — no PDFs needed for these tests)
    private func makeTempWorkspace() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultIndexerTests-\(UUID().uuidString)")
        let vault = dir.appendingPathComponent("vault")
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("papers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sources"), withIntermediateDirectories: true)
        return dir.path
    }

    /// Write a minimal valid frontmatter markdown file.
    private func write(
        at path: String,
        type: String = "paper",
        title: String = "Test Paper",
        body: String = "Some body text for search."
    ) throws {
        let content = """
        ---
        type: \(type)
        title: \(title)
        ---
        \(body)
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Bump the modification date of a file to `Date() + offset` so mtime definitely changes.
    private func touch(_ path: String, offset: TimeInterval = 2.0) throws {
        let newDate = Date().addingTimeInterval(offset)
        try FileManager.default.setAttributes(
            [.modificationDate: newDate], ofItemAtPath: path)
    }

    private func writeRaw(at path: String, _ content: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func entriesRevision(_ indexPath: String) throws -> Int64 {
        try DatabaseQueue(path: indexPath).read { db in
            try IndexWriter.entriesRevision(db)
        }
    }

    private func entryCount(_ indexPath: String, path: String) throws -> Int {
        try DatabaseQueue(path: indexPath).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE path = ?", arguments: [path]) ?? 0
        }
    }

    @discardableResult
    private func awaitFile(_ path: String, seconds: Double = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Convenience: open IndexDatabase at the workspace's index path.
    private func openDB(_ workspaceRoot: String) -> IndexDatabase {
        let indexPath = workspaceRoot + "/.marple/index.sqlite"
        return IndexDatabase(indexDBPath: indexPath)
    }

    // MARK: - buildFull

    @Test("buildFull returns correct entry count for 2 valid files")
    func buildFullReturnsTwoEntries() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")
        try write(at: ws + "/vault/notes/b.md", type: "note", title: "Note B")

        let indexer = VaultIndexer(workspaceRoot: ws)
        let count = try indexer.buildFull()

        #expect(count == 2)
    }

    @Test("buildFull produces a readable index via IndexDatabase")
    func buildFullProducesReadableIndex() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")
        try write(at: ws + "/vault/notes/b.md", type: "note", title: "Note B")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let entries = try openDB(ws).loadEntries()
        #expect(entries.count == 2)
        let paths = entries.map(\.path).sorted()
        #expect(paths == ["vault/notes/b.md", "vault/papers/a.md"])
    }

    @Test("buildFull leaves the live DB in WAL mode")
    func buildFullLeavesWALMode() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let indexPath = ws + "/.marple/index.sqlite"
        // Open a connection and check journal_mode = wal
        let queue = try DatabaseQueue(path: indexPath)
        let mode = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(mode?.lowercased() == "wal")
    }

    // MARK: - reconcile when index missing

    @Test("reconcile builds the index when none exists")
    func reconcileBuildsWhenMissing() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")
        try write(at: ws + "/vault/notes/b.md", type: "note", title: "Note B")

        let indexer = VaultIndexer(workspaceRoot: ws)
        let stats = try indexer.reconcile()

        // No prior index → behaves like buildFull → upserted == count
        #expect(stats.upserted == 2)
        #expect(stats.removed == 0)
        #expect(stats.unchanged == 0)

        let entries = try openDB(ws).loadEntries()
        #expect(entries.count == 2)
    }

    // MARK: - reconcile delta

    @Test("reconcile diffs: upserts new+modified, deletes vanished")
    func reconcileDelta() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")
        try write(at: ws + "/vault/notes/b.md", type: "note", title: "Note B")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        // Add a new file, modify a.md, and delete b.md
        try write(at: ws + "/vault/papers/c.md", type: "paper", title: "Paper C")
        // Re-write a.md with new content AND explicitly bump mtime
        try write(at: ws + "/vault/papers/a.md", type: "paper",
                  title: "Paper A Updated", body: "New body text after update.")
        try touch(ws + "/vault/papers/a.md", offset: 10.0)
        try FileManager.default.removeItem(atPath: ws + "/vault/notes/b.md")

        let stats = try indexer.reconcile()

        // a.md and c.md were upserted (2); b.md was removed (1); nothing unchanged
        #expect(stats.upserted >= 2)
        #expect(stats.removed == 1)

        let entries = try openDB(ws).loadEntries()
        // b.md deleted → 2 entries remain (a, c)
        #expect(entries.count == 2)
        let paths = entries.map(\.path).sorted()
        #expect(paths == ["vault/papers/a.md", "vault/papers/c.md"])
    }

    @Test("second reconcile with no changes is all unchanged")
    func reconcileSecondCallNoChanges() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")
        try write(at: ws + "/vault/notes/b.md", type: "note", title: "Note B")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let stats = try indexer.reconcile()

        #expect(stats.upserted == 0)
        #expect(stats.removed == 0)
        #expect(stats.unchanged == 2)
    }

    // MARK: - dotfiles and .trash exclusion

    @Test("dotfiles and .trash directories are excluded")
    func dotfilesAndTrashExcluded() throws {
        let ws = try makeTempWorkspace()
        // One real file
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")

        // A dotfile at the root vault level
        try ".hidden".write(toFile: ws + "/vault/.hidden.md", atomically: true, encoding: .utf8)

        // A .trash directory with a valid frontmatter file inside
        let trashDir = ws + "/vault/.trash"
        try FileManager.default.createDirectory(
            atPath: trashDir, withIntermediateDirectories: true)
        try write(at: trashDir + "/trashed.md", type: "paper", title: "Trashed")

        let indexer = VaultIndexer(workspaceRoot: ws)
        let count = try indexer.buildFull()

        // Only a.md is indexed; .hidden.md and .trash/trashed.md must be skipped
        #expect(count == 1)
        let entries = try openDB(ws).loadEntries()
        #expect(entries.count == 1)
        #expect(entries[0].path == "vault/papers/a.md")
    }

    // MARK: - files without valid frontmatter are skipped (not counted)

    @Test("files without frontmatter are skipped (not counted in buildFull)")
    func filesWithoutFrontmatterSkipped() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")
        // plain markdown, no frontmatter fence
        try "# Just a heading\n\nSome text.".write(
            toFile: ws + "/vault/notes/plain.md", atomically: true, encoding: .utf8)

        let indexer = VaultIndexer(workspaceRoot: ws)
        let count = try indexer.buildFull()

        #expect(count == 1)
    }

    // MARK: - canSkipFullBuild

    @Test("canSkipFullBuild is false before any build runs")
    func canSkipFullBuildFalseWhenMissing() throws {
        let ws = try makeTempWorkspace()
        let indexer = VaultIndexer(workspaceRoot: ws)
        #expect(indexer.canSkipFullBuild() == false)
    }

    @Test("canSkipFullBuild is true after a successful buildFull")
    func canSkipFullBuildTrueAfterBuild() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")
        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()
        #expect(indexer.canSkipFullBuild() == true)
    }

    @Test("canSkipFullBuild is false when schema is stale")
    func canSkipFullBuildFalseOnStaleSchema() throws {
        let ws = try makeTempWorkspace()
        // Plant a DB with a stripped schema — same shape as the stale-schema test below.
        let marpleDir = ws + "/.marple"
        try FileManager.default.createDirectory(atPath: marpleDir, withIntermediateDirectories: true)
        let indexPath = marpleDir + "/index.sqlite"
        let queue = try DatabaseQueue(path: indexPath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE entries (
                  path TEXT PRIMARY KEY,
                  type TEXT NOT NULL
                );
                """)
        }
        let indexer = VaultIndexer(workspaceRoot: ws)
        #expect(indexer.canSkipFullBuild() == false)
    }

    // MARK: - reconcile when schema is stale

    /// QUA-102 migration: a DB built by the older marple has all required
    /// `entries` columns but still carries `entry_search` (the retired 12-col
    /// FTS5 table). `canSkipFullBuild` must return false so boot rebuilds the
    /// DB instead of opening 1.4 GB of bloat.
    @Test("canSkipFullBuild is false when retired entry_search table is present")
    func canSkipFullBuildFalseOnRetiredEntrySearch() throws {
        let ws = try makeTempWorkspace()
        let marpleDir = ws + "/.marple"
        try FileManager.default.createDirectory(atPath: marpleDir, withIntermediateDirectories: true)
        let indexPath = marpleDir + "/index.sqlite"
        let queue = try DatabaseQueue(path: indexPath)
        // Plant a DB with all required `entries` columns AND a stub entry_search
        // — the smoking gun for "built by an older marple".
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE entries (
                  path TEXT PRIMARY KEY, type TEXT NOT NULL, book TEXT, title TEXT,
                  title_en TEXT, title_cn TEXT, author TEXT, year_json TEXT, rating_json TEXT,
                  rating_score REAL NOT NULL DEFAULT 0, themes_json TEXT, topic TEXT, source TEXT,
                  doi TEXT, publisher TEXT, isbn TEXT, category TEXT, translation_title_cn TEXT,
                  translation_douban_url TEXT, chapters_analyzed INTEGER, annotates TEXT,
                  created TEXT, pdf_slug TEXT, has_pdf INTEGER NOT NULL DEFAULT 0, mtime INTEGER,
                  preview TEXT NOT NULL DEFAULT '', body_len INTEGER NOT NULL DEFAULT 0,
                  added INTEGER NOT NULL DEFAULT 0
                );
                CREATE VIRTUAL TABLE entry_search USING fts5(
                  path UNINDEXED, type UNINDEXED, title, author, book, themes,
                  topic, source, year, preview, doi, body
                );
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO meta(key, value) VALUES ('schema_version', '2');
                """)
        }
        // meta.schema_version is current — the only stale signal is the
        // presence of `entry_search`. This proves canSkipFullBuild rejects
        // the DB on the entry_search check rather than only via schema_version.
        let indexer = VaultIndexer(workspaceRoot: ws)
        #expect(indexer.canSkipFullBuild() == false)
    }

    // MARK: - QUA-104: entries_revision + cache invalidation

    @Test("buildFull bumps entries_revision and removes a stale entries.cache")
    func buildFullBumpsRevisionAndNukesCache() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")

        // Plant a stale cache before any build runs — buildFull must delete it.
        let marpleDir = ws + "/.marple"
        try FileManager.default.createDirectory(atPath: marpleDir, withIntermediateDirectories: true)
        let cachePath = marpleDir + "/entries.cache"
        try Data("stale-cache-bytes".utf8).write(to: URL(fileURLWithPath: cachePath))
        #expect(FileManager.default.fileExists(atPath: cachePath))

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        // Cache file is gone — next loadEntries will rebuild it from the new DB.
        #expect(!FileManager.default.fileExists(atPath: cachePath))

        // entries_revision is non-zero after a successful build.
        let queue = try DatabaseQueue(path: ws + "/.marple/index.sqlite")
        let rev = try queue.read { db in try IndexWriter.entriesRevision(db) }
        #expect(rev > 0)
    }

    @Test("reconcile bumps entries_revision when there are changes")
    func reconcileBumpsRevisionOnChange() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let indexPath = ws + "/.marple/index.sqlite"
        let revBefore = try DatabaseQueue(path: indexPath).read { db in
            try IndexWriter.entriesRevision(db)
        }

        // Add a new file → reconcile upserts it → revision should bump.
        try write(at: ws + "/vault/papers/b.md", type: "paper", title: "Paper B")
        let stats = try indexer.reconcile()
        #expect(stats.upserted >= 1)

        let revAfter = try DatabaseQueue(path: indexPath).read { db in
            try IndexWriter.entriesRevision(db)
        }
        #expect(revAfter > revBefore)
    }

    @Test("reconcile refreshes metadata visible through an existing entries cache")
    func reconcileRefreshesMetadataThroughExistingEntriesCache() throws {
        let ws = try makeTempWorkspace()
        let path = ws + "/vault/papers/a.md"
        try write(at: path, type: "paper", title: "Paper A")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let db = openDB(ws)
        let cachePath = ws + "/.marple/entries.cache"
        #expect(try db.loadEntries().first?.title == "Paper A")
        #expect(awaitFile(cachePath), "entries cache should exist before the external edit")

        try write(at: path, type: "paper", title: "Paper A Updated")
        try touch(path)

        let stats = try indexer.reconcile()
        #expect(stats.upserted == 1)

        let entries = try db.loadEntries()
        #expect(entries.first { $0.path == "vault/papers/a.md" }?.title == "Paper A Updated")
    }

    @Test("reconcile indexes a newly copied note through an existing entries cache")
    func reconcileIndexesNewCopiedNoteThroughExistingEntriesCache() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let db = openDB(ws)
        let cachePath = ws + "/.marple/entries.cache"
        #expect(try db.loadEntries().count == 1)
        #expect(awaitFile(cachePath), "entries cache should exist before the external copy")

        let copied = ws + "/vault/notes/iphone2.md"
        try writeRaw(at: copied, """
        ---
        type: note
        title: "搞你的 iPhone2"
        created: 2026-05-18
        ---
        """)
        try touch(copied)

        let stats = try indexer.reconcile()
        #expect(stats.upserted == 1)

        let entries = try db.loadEntries()
        let note = entries.first { $0.path == "vault/notes/iphone2.md" }
        #expect(note?.type == .note)
        #expect(note?.title == "搞你的 iPhone2")
    }

    @Test("reconcile does NOT bump entries_revision when nothing changed")
    func reconcileNoBumpWhenUnchanged() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let indexPath = ws + "/.marple/index.sqlite"
        let revBefore = try DatabaseQueue(path: indexPath).read { db in
            try IndexWriter.entriesRevision(db)
        }

        // No file changes → reconcile finds everything unchanged → revision stays.
        let stats = try indexer.reconcile()
        #expect(stats.upserted == 0)
        #expect(stats.removed == 0)

        let revAfter = try DatabaseQueue(path: indexPath).read { db in
            try IndexWriter.entriesRevision(db)
        }
        #expect(revAfter == revBefore)
    }

    @Test("reconcile rolls back partial writes when a later upsert fails")
    func reconcileRollsBackPartialWritesOnFailure() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let indexPath = ws + "/.marple/index.sqlite"
        let revBefore = try entriesRevision(indexPath)

        try write(at: ws + "/vault/papers/b.md", type: "paper", title: "Paper B")
        try writeRaw(at: ws + "/vault/papers/c.md", """
        ---
        type: paper
        title: Broken Paper
        themes: [duplicate, duplicate]
        ---
        body
        """)

        do {
            _ = try indexer.reconcile()
            Issue.record("expected reconcile to throw")
        } catch {
        }

        #expect(try entriesRevision(indexPath) == revBefore)
        #expect(try entryCount(indexPath, path: "vault/papers/b.md") == 0)
    }

    @Test("reconcile bumps entries_revision when an indexed file becomes skipped")
    func reconcileBumpsRevisionWhenIndexedFileBecomesSkipped() throws {
        let ws = try makeTempWorkspace()
        let path = ws + "/vault/papers/a.md"
        try write(at: path, type: "paper", title: "Paper A")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        let indexPath = ws + "/.marple/index.sqlite"
        let revBefore = try entriesRevision(indexPath)

        try writeRaw(at: path, "# Paper A\n\nNo frontmatter anymore.")
        try touch(path)

        let stats = try indexer.reconcile()

        #expect(stats.upserted == 0)
        #expect(stats.removed == 1)
        #expect(try entryCount(indexPath, path: "vault/papers/a.md") == 0)
        #expect(try entriesRevision(indexPath) > revBefore)
    }

    @Test("reconcile triggers full build when schema is stale")
    func reconcileFullBuildOnStaleSchema() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper", title: "Paper A")

        // Manually create a DB with a stripped (stale) schema — missing required columns
        let marpleDir = ws + "/.marple"
        try FileManager.default.createDirectory(atPath: marpleDir, withIntermediateDirectories: true)
        let indexPath = marpleDir + "/index.sqlite"
        let queue = try DatabaseQueue(path: indexPath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE entries (
                  path TEXT PRIMARY KEY,
                  type TEXT NOT NULL
                );
                INSERT INTO entries (path, type) VALUES ('vault/papers/a.md', 'paper');
                """)
        }

        let indexer = VaultIndexer(workspaceRoot: ws)
        let stats = try indexer.reconcile()

        // Stale schema detected → full rebuild → upserted == 1 (a.md)
        #expect(stats.upserted == 1)
        #expect(stats.removed == 0)

        // After rebuild, DB has the full schema
        let entries = try openDB(ws).loadEntries()
        #expect(entries.count == 1)
        #expect(entries[0].path == "vault/papers/a.md")
    }
}
