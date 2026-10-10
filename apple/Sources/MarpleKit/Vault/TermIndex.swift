import Foundation
import GRDB

public struct TermIndexStatus: Codable, Equatable, Sendable {
    public let terms: Int
    public let relations: Int
    public let sourceDocuments: Int
    public let scannedDocuments: Int
    public let updatedAt: Date
}

public struct TermMatch: Codable, Equatable, Sendable {
    public let term: String
    public let sources: [TermRecord]
}

/// One writer per vault. All refreshes and lookups are serialized by the actor;
/// a refresh commits file fingerprints, correspondences and metadata together.
public actor TermIndex {
    public nonisolated let databasePath: String
    private let workspaceRoot: String
    private var pool: DatabasePool?

    public init(workspaceRoot: String, databasePath: String? = nil) {
        self.workspaceRoot = workspaceRoot
        self.databasePath = databasePath ?? workspaceRoot + "/.marple/terms.sqlite"
    }

    private func database() throws -> DatabasePool {
        if let pool { return pool }
        try FileManager.default.createDirectory(
            atPath: (databasePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(path: databasePath, configuration: config)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS files (
                    path TEXT PRIMARY KEY, mtime REAL NOT NULL, size INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS pairs (
                    path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
                    line INTEGER NOT NULL,
                    chinese TEXT NOT NULL, english TEXT NOT NULL,
                    chinese_key TEXT NOT NULL, english_key TEXT NOT NULL,
                    chinese_cell TEXT NOT NULL, english_cell TEXT NOT NULL,
                    definition TEXT,
                    PRIMARY KEY (path, line, chinese_key, english_key)
                );
                CREATE INDEX IF NOT EXISTS pairs_chinese ON pairs(chinese_key);
                CREATE INDEX IF NOT EXISTS pairs_english ON pairs(english_key);
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        }
        self.pool = pool
        return pool
    }

    public func status() throws -> TermIndexStatus? {
        guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
        return try database().read(Self.readStatus)
    }

    @discardableResult
    public func refresh(rebuild: Bool = false) throws -> TermIndexStatus {
        let vault = URL(fileURLWithPath: workspaceRoot).appendingPathComponent("vault").resolvingSymlinksInPath()
        // An unavailable vault must not look like an empty vault and erase rows.
        _ = try FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil)
        var walkError: Error?
        guard let walker = FileManager.default.enumerator(at: vault,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in
                walkError = error
                return false
            }) else { throw CocoaError(.fileReadUnknown) }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            let kind = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if kind.isRegularFile == true || kind.isSymbolicLink == true {
                files.append(url)
            }
        }
        if let walkError { throw walkError }
        let pool = try database()
        return try pool.write { db in
            let version = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'parser_version'")
            let full = rebuild || version != String(TermParser.version)
            if full { try db.execute(sql: "DELETE FROM files") }
            let oldRows = try Row.fetchAll(db, sql: "SELECT path, mtime, size FROM files")
            let old = Dictionary(uniqueKeysWithValues: oldRows.map { ($0["path"] as String, $0) })
            var seen = Set<String>()
            var changed = full
            for url in files.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                // FileManager may switch /var and /private/var spellings after
                // a rename. Normalize the prefix without resolving file aliases.
                let prefix = Self.filesystemPath(vault) + "/"
                let filePath = Self.filesystemPath(url)
                guard filePath.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
                let path = "vault/" + filePath.dropFirst(prefix.count)
                seen.insert(path)
                let isAlias = try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
                let contentURL = isAlias ? url.resolvingSymlinksInPath() : url
                let values = try contentURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let date = values.contentModificationDate, let size = values.fileSize else {
                    throw CocoaError(.fileReadUnknown)
                }
                let mtime = date.timeIntervalSince1970
                if let row = old[path], row["mtime"] as Double == mtime, row["size"] as Int == size { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let records = TermParser.parse(text, path: path)
                try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [path])
                try db.execute(sql: "INSERT INTO files VALUES (?, ?, ?)", arguments: [path, mtime, size])
                for record in records {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO pairs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [path, record.line, record.chinese, record.english,
                            TermParser.key(record.chinese), TermParser.key(record.english),
                            record.chineseCell, record.englishCell, record.definition])
                }
                changed = true
            }
            for path in old.keys where !seen.contains(path) {
                try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [path])
                changed = true
            }
            if changed {
                try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES ('parser_version', ?)",
                    arguments: [String(TermParser.version)])
                try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES ('updated_at', ?)",
                    arguments: [String(Date().timeIntervalSince1970)])
            }
            return try Self.readStatus(db)!
        }
    }

    public func lookup(_ term: String) throws -> [TermMatch] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        let key = TermParser.key(term)
        return try database().read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM pairs WHERE chinese_key = ? OR english_key = ? ORDER BY path, line
                """, arguments: [key, key])
            var matches: [String: [TermRecord]] = [:]
            var labels: [String: String] = [:]
            for row in rows {
                let opposite: String = row["chinese_key"] == key ? row["english"] : row["chinese"]
                let oppositeKey = TermParser.key(opposite)
                if labels[oppositeKey] == nil { labels[oppositeKey] = opposite }
                matches[oppositeKey, default: []].append(TermRecord(
                    chinese: row["chinese"], english: row["english"],
                    chineseCell: row["chinese_cell"], englishCell: row["english_cell"],
                    definition: row["definition"], path: row["path"], line: row["line"]))
            }
            return matches.keys.sorted().map { TermMatch(term: labels[$0]!, sources: matches[$0]!) }
        }
    }

    private static func readStatus(_ db: Database) throws -> TermIndexStatus? {
        guard let timestamp = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'updated_at'"),
              let seconds = Double(timestamp) else { return nil }
        return try TermIndexStatus(
            terms: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT chinese_key FROM pairs UNION SELECT english_key FROM pairs)") ?? 0,
            relations: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT DISTINCT chinese_key, english_key FROM pairs)") ?? 0,
            sourceDocuments: Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT path) FROM pairs") ?? 0,
            scannedDocuments: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0,
            updatedAt: Date(timeIntervalSince1970: seconds))
    }

    private static func filesystemPath(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
