import Foundation

#if os(macOS)
/// Append-only persistent log for Reader AI dispatch failures. GUI-launched apps
/// don't inherit a console, so `print()` to stdout is invisible — yet the
/// failure messages tell the user to "请查看日志". This writes the exit code
/// and stderr to a file they can actually open, making that hint true.
public struct ReaderAILog: Sendable {
    public static let shared = ReaderAILog()

    let fileURL: URL

    public init(fileURL: URL = ReaderAILog.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// ~/Library/Logs/Marple/reader-ai.log — the conventional macOS location
    /// surfaced by Console.app and easy to point users at.
    public static var defaultFileURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Marple", isDirectory: true)
            .appendingPathComponent("reader-ai.log")
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

    // Cached once: ISO8601DateFormatter is costly to allocate and was created per
    // log line. Default config → byte-identical output. nonisolated(unsafe): we
    // only ever read it (string(from:)), which is thread-safe.
    private nonisolated(unsafe) static let timestampFormatter = ISO8601DateFormatter()

    static func line(_ message: String, timestamp: Date) -> String {
        "[\(timestampFormatter.string(from: timestamp))] \(message)\n"
    }
}
#endif
