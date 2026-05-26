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
        type: String = "paper-analysis",
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

    /// Convenience: open IndexDatabase at the workspace's index path.
    private func openDB(_ workspaceRoot: String) -> IndexDatabase {
        let indexPath = workspaceRoot + "/.marple/index.sqlite"
        return IndexDatabase(indexDBPath: indexPath)
    }

    // MARK: - buildFull

    @Test("buildFull returns correct entry count for 2 valid files")
    func buildFullReturnsTwoEntries() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")
        try write(at: ws + "/vault/notes/b.md", type: "note", title: "Note B")

        let indexer = VaultIndexer(workspaceRoot: ws)
        let count = try indexer.buildFull()

        #expect(count == 2)
    }

    @Test("buildFull produces a readable index via IndexDatabase")
    func buildFullProducesReadableIndex() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")
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
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")

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
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")
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
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")
        try write(at: ws + "/vault/notes/b.md", type: "note", title: "Note B")

        let indexer = VaultIndexer(workspaceRoot: ws)
        _ = try indexer.buildFull()

        // Add a new file, modify a.md, and delete b.md
        try write(at: ws + "/vault/papers/c.md", type: "paper-analysis", title: "Paper C")
        // Re-write a.md with new content AND explicitly bump mtime
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis",
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
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")
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
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")

        // A dotfile at the root vault level
        try ".hidden".write(toFile: ws + "/vault/.hidden.md", atomically: true, encoding: .utf8)

        // A .trash directory with a valid frontmatter file inside
        let trashDir = ws + "/vault/.trash"
        try FileManager.default.createDirectory(
            atPath: trashDir, withIntermediateDirectories: true)
        try write(at: trashDir + "/trashed.md", type: "paper-analysis", title: "Trashed")

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
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")
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
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")
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

    @Test("reconcile triggers full build when schema is stale")
    func reconcileFullBuildOnStaleSchema() throws {
        let ws = try makeTempWorkspace()
        try write(at: ws + "/vault/papers/a.md", type: "paper-analysis", title: "Paper A")

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
                INSERT INTO entries (path, type) VALUES ('vault/papers/a.md', 'paper-analysis');
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
