import Testing
import Foundation
@testable import MarpleKit

// MARK: - Helpers

private func runGit(_ args: [String], cwd: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["git"] + args
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    // Suppress git output in test logs
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
}

private func makeTempDir() throws -> String {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitDatesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp.path
}

@Suite("GitDates")
struct GitDatesTests {

    // MARK: - gitAddedDates / gitAddedDate basic round-trip

    @Test("gitAddedDates: committed file gets epoch-ms > 0")
    func committedFileHasDate() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Init the repo
        try runGit(["-c", "init.defaultBranch=main", "init", tmp], cwd: tmp)

        // Create vault/papers/a.md
        let vaultPapers = tmp + "/vault/papers"
        try FileManager.default.createDirectory(atPath: vaultPapers, withIntermediateDirectories: true)
        try "hello".write(toFile: vaultPapers + "/a.md", atomically: true, encoding: .utf8)

        // Stage and commit with local identity (no global config touched)
        try runGit(["-C", tmp, "-c", "user.email=t@t", "-c", "user.name=t",
                    "add", "vault/papers/a.md"], cwd: tmp)
        try runGit(["-C", tmp, "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-m", "add a"], cwd: tmp)

        let map = gitAddedDates(workspaceRoot: tmp)
        #expect(map["vault/papers/a.md"] != nil)
        let ms = map["vault/papers/a.md"]!
        #expect(ms > 0)

        let single = gitAddedDate(workspaceRoot: tmp, relPath: "vault/papers/a.md")
        #expect(single == ms)
    }

    // MARK: - First occurrence wins

    @Test("gitAddedDates: first occurrence wins across multiple commits")
    func firstOccurrenceWins() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try runGit(["-c", "init.defaultBranch=main", "init", tmp], cwd: tmp)

        let vault = tmp + "/vault"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        try "first".write(toFile: vault + "/a.md", atomically: true, encoding: .utf8)

        let gitConfig = ["-C", tmp, "-c", "user.email=t@t", "-c", "user.name=t"]

        try runGit(gitConfig + ["add", "vault/a.md"], cwd: tmp)
        try runGit(gitConfig + ["commit", "-m", "first"], cwd: tmp)

        // Record the date of the first commit
        let firstMs = gitAddedDate(workspaceRoot: tmp, relPath: "vault/a.md")
        #expect(firstMs > 0)

        // Modify the file in a second commit (diff-filter=A should NOT catch this)
        try "second".write(toFile: vault + "/a.md", atomically: true, encoding: .utf8)
        try runGit(gitConfig + ["add", "vault/a.md"], cwd: tmp)
        try runGit(gitConfig + ["commit", "-m", "modify"], cwd: tmp)

        let map = gitAddedDates(workspaceRoot: tmp)
        // The date must still equal the first commit (first wins, not overwritten)
        #expect(map["vault/a.md"] == firstMs)
    }

    // MARK: - Uncommitted / nonexistent path

    @Test("gitAddedDate: uncommitted path → 0")
    func uncommittedPath() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try runGit(["-c", "init.defaultBranch=main", "init", tmp], cwd: tmp)

        // Repo exists but vault/papers/missing.md was never committed
        let single = gitAddedDate(workspaceRoot: tmp, relPath: "vault/papers/missing.md")
        #expect(single == 0)
    }

    @Test("gitAddedDates: uncommitted path not in map")
    func uncommittedPathNotInMap() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try runGit(["-c", "init.defaultBranch=main", "init", tmp], cwd: tmp)

        let map = gitAddedDates(workspaceRoot: tmp)
        #expect(map["vault/papers/missing.md"] == nil)
    }

    // MARK: - Non-git directory

    @Test("gitAddedDates: non-git dir → empty map, no crash")
    func nonGitDirMap() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // No git init — just a bare directory
        let map = gitAddedDates(workspaceRoot: tmp)
        #expect(map.isEmpty)
    }

    @Test("gitAddedDate: non-git dir → 0, no crash")
    func nonGitDirSingle() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let ms = gitAddedDate(workspaceRoot: tmp, relPath: "vault/papers/a.md")
        #expect(ms == 0)
    }
}
