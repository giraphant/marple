import Foundation

// MARK: - Git-derived added dates
//
// Mirrors the Rust functions `git_added_dates` and `git_added_date` in
// rust/reader-core/src/indexer.rs (:769-824).

/// Parse an RFC3339 string produced by `git log --format=%aI` into epoch milliseconds.
/// Returns nil if the string cannot be parsed.
/// We try with fractional seconds first (some tools emit them), then without.
private func parseRFC3339(_ s: String) -> Int64? {
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: s) {
        return Int64(d.timeIntervalSince1970 * 1000)
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: s) {
        return Int64(d.timeIntervalSince1970 * 1000)
    }
    return nil
}

/// Run `git` via `/usr/bin/env` and capture stdout.
/// Returns nil on launch failure, non-zero exit, or any other error.
private func runGitCapture(_ args: [String], workspaceRoot: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + args
    // Run in the workspace root so relative paths resolve correctly.
    // We also pass -C workspaceRoot as the first git arg, matching Rust exactly.
    process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()

    guard process.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

// MARK: - Public API

/// Map of git-relative path → epoch-ms of the file's FIRST (add) commit.
/// First occurrence wins. Empty on any git failure.
/// Mirrors Rust `git_added_dates` (indexer.rs :769-805).
///
/// Git command:
///   git -C <workspaceRoot> log --diff-filter=A --reverse --format=%aI --name-only -- vault
public func gitAddedDates(workspaceRoot: String) -> [String: Int64] {
    var map = [String: Int64]()

    let output = runGitCapture(
        ["-C", workspaceRoot,
         "log",
         "--diff-filter=A",
         "--reverse",
         "--format=%aI",
         "--name-only",
         "--",
         "vault"],
        workspaceRoot: workspaceRoot
    )
    guard let text = output else { return map }

    var current: Int64 = 0
    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if let ms = parseRFC3339(line) {
            // This line is a timestamp — set the current epoch
            current = ms
        } else {
            // This line is a file path — record it (first occurrence wins)
            if map[line] == nil {
                map[line] = current
            }
        }
    }
    return map
}

/// Epoch-ms of one path's first commit, 0 if none / git fails.
/// Mirrors Rust `git_added_date` (indexer.rs :807-824).
///
/// Git command:
///   git -C <workspaceRoot> log --diff-filter=A --reverse --format=%aI -- <relPath>
public func gitAddedDate(workspaceRoot: String, relPath: String) -> Int64 {
    let output = runGitCapture(
        ["-C", workspaceRoot,
         "log",
         "--diff-filter=A",
         "--reverse",
         "--format=%aI",
         "--",
         relPath],
        workspaceRoot: workspaceRoot
    )
    guard let text = output else { return 0 }

    // Find the first line that parses as an RFC3339 timestamp
    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if let ms = parseRFC3339(line) {
            return ms
        }
    }
    return 0
}
