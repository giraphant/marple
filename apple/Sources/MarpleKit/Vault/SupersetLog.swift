import Foundation

/// Append-only persistent log for Superset CLI failures. GUI-launched apps
/// don't inherit a console, so `print()` to stdout is invisible — yet the
/// failure messages tell the user to "请查看日志". This writes the exit code
/// and stderr to a file they can actually open, making that hint true.
public struct SupersetLog: Sendable {
    public static let shared = SupersetLog()

    let fileURL: URL

    public init(fileURL: URL = SupersetLog.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// ~/Library/Logs/Marple/superset.log — the conventional macOS location
    /// surfaced by Console.app and easy to point users at.
    public static var defaultFileURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Marple", isDirectory: true)
            .appendingPathComponent("superset.log")
    }

    public func append(_ message: String, timestamp: Date = Date()) {
        guard let data = Self.line(message, timestamp: timestamp).data(using: .utf8) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func line(_ message: String, timestamp: Date) -> String {
        "[\(ISO8601DateFormatter().string(from: timestamp))] \(message)\n"
    }
}
