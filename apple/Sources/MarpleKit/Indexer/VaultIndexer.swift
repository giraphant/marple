import Foundation
import GRDB

// MARK: - ReconcileStats

/// Statistics from a delta reconcile pass. Mirrors `ReconcileStats` in
/// `rust/reader-core/src/indexer.rs` (:313-321).
public struct ReconcileStats: Sendable, Equatable {
    public var upserted: Int = 0
    public var removed: Int = 0
    public var unchanged: Int = 0

    public init(upserted: Int = 0, removed: Int = 0, unchanged: Int = 0) {
        self.upserted = upserted
        self.removed = removed
        self.unchanged = unchanged
    }
}

// MARK: - VaultIndexer

/// Builds and incrementally reconciles the Marple SQLite index.
///
/// Mirrors `build_sqlite_index` (:247-311), `reconcile_index` (:350-425),
/// `upsert_path_in_conn`, `delete_path_rows`, `mtime_ms`, and the
/// `INDEX_WRITE_LOCK` static mutex in `rust/reader-core/src/indexer.rs`.
///
/// **Thread safety:** `VaultIndexer` is marked `@unchecked Sendable`; the
/// `writeLock` NSLock serialises all mutations on the live DB (including the
/// atomic temp→live rename). The class itself is `final` and every property
/// that crosses actor boundaries is either let-bound or accessed under the lock.
public final class VaultIndexer: @unchecked Sendable {

    // MARK: - Paths

    /// Workspace root (e.g. the repo checkout containing `vault/` and `sources/`).
    private let workspaceRoot: String

    /// Path of the live index DB: `<workspaceRoot>/.marple/index.sqlite`.
    private let indexDBPath: String

    /// Path of the vault directory: `<workspaceRoot>/vault`.
    private let vaultPath: String

    /// Path of the sources directory: `<workspaceRoot>/sources`.
    private let sourcesPath: String

    /// Vocabulary table loaded once per indexer instance (builtin + optional
    /// vault/schema/schema.yaml override). Immutable thereafter — a schema edit needs
    /// an app relaunch, same as today's rebuild semantics.
    private let schema: VaultSchema

    // MARK: - Write lock (mirrors INDEX_WRITE_LOCK in Rust)

    /// Serialises every mutation of the live index file — both the atomic
    /// tmp→live rename in `buildFull` and the per-entry upsert/delete rows in
    /// `reconcile`.  Mirrors `static INDEX_WRITE_LOCK: Mutex<()>` in indexer.rs.
    private let writeLock = NSLock()

    /// Directory containing the index DB — the parent of `indexDBPath`. On macOS
    /// this is `<workspaceRoot>/.marple`; on iOS it is the app's private container.
    private var indexDBDir: String { (indexDBPath as NSString).deletingLastPathComponent }

    // MARK: - init

    public init(workspaceRoot: String, indexDBPath: String? = nil) {
        self.workspaceRoot = workspaceRoot
        self.indexDBPath  = indexDBPath ?? (workspaceRoot + "/.marple/index.sqlite")
        self.vaultPath    = workspaceRoot + "/vault"
        self.sourcesPath  = workspaceRoot + "/sources"
        self.schema       = VaultSchema.load(workspaceRoot: workspaceRoot)
    }

    // MARK: - buildFull

    /// Full rebuild: walk vault → parse → sort → write temp DB → atomic rename →
    /// flip to WAL. Returns the number of indexed entries.
    ///
    /// Mirrors `build_sqlite_index` (:247-311) + `write_sqlite_index` (:1160-1281).
    @discardableResult
    public func buildFull() throws -> Int {
        // 1. Walk + parse (outside the lock — slow phase).
        let files = try walkMarkdown(vaultPath)
        let sourceSlugs = loadSourceSlugs(sourcesDir: sourcesPath)
        let sourceIndex = SourceSlugIndex(sourceSlugs)
        let addedDates  = gitAddedDates(workspaceRoot: workspaceRoot)

        var entries: [IndexedEntry] = []
        var seen = Set<String>()
        for file in files {
            let rel = slashRelative(root: workspaceRoot, path: file)
            // Defensive: never insert the same path twice (entries.path is the PK).
            // Should not happen now that slashRelative no longer collapses symlinks,
            // but a stray duplicate must not abort the whole build.
            if !seen.insert(rel).inserted {
                print("[indexer] skipping duplicate path: \(rel)")
                continue
            }
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let fileStem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            let mtimeMs  = Self.mtimeMs(atPath: file)

            let outcome = buildIndexedEntry(
                text: text,
                rel: rel,
                fileStem: fileStem,
                sourceSlugs: sourceSlugs,
                mtimeMs: mtimeMs,
                sourceIndex: sourceIndex,
                schema: schema
            )
            guard case .indexed(var entry) = outcome else { continue }
            entry.added = addedDates[rel] ?? 0
            Self.deriveImageFields(&entry, absPath: file)
            entries.append(entry)
        }

        // 2. Sort: type ASC, ratingScore DESC, title/path ASC.
        //    Mirrors the sort in `build_sqlite_index` (:281-290).
        entries.sort { a, b in
            if a.entryType != b.entryType { return a.entryType < b.entryType }
            if a.ratingScore != b.ratingScore { return a.ratingScore > b.ratingScore }
            let at = a.title ?? a.path
            let bt = b.title ?? b.path
            return at < bt
        }

        // 3. Ensure the index DB directory exists.
        let marpleDir = indexDBDir
        try FileManager.default.createDirectory(
            atPath: marpleDir, withIntermediateDirectories: true, attributes: nil)

        // 4. Write to temp file with journal_mode=OFF + synchronous=OFF for speed.
        //    Mirrors `write_sqlite_index` (:1160-1281).
        let tmpPath = indexDBPath + ".tmp"
        if FileManager.default.fileExists(atPath: tmpPath) {
            try FileManager.default.removeItem(atPath: tmpPath)
        }

        // Build into the temp DB (DatabaseQueue → single connection, no WAL).
        do {
            var config = Configuration()
            config.label = "MarpleIndexer.tmp"
            let tmpQueue = try DatabaseQueue(path: tmpPath, configuration: config)

            try tmpQueue.writeWithoutTransaction { db in
                // Bulk-speed pragmas (mirrors PRAGMA journal_mode=OFF + synchronous=OFF)
                try db.execute(sql: "PRAGMA journal_mode=OFF")
                try db.execute(sql: "PRAGMA synchronous=OFF")
            }

            try tmpQueue.write { db in
                try IndexWriter.createSchema(db)
                for entry in entries {
                    try IndexWriter.insert(db, entry)
                }
                // QUA-104: bump revision in the same transaction so any
                // surviving entries.cache from before this rebuild is
                // invalidated on next loadEntries.
                try IndexWriter.bumpEntriesRevision(db)
            }
            // Ensure all writes are flushed before we close the queue.
        }
        // tmpQueue is deallocated here, closing its connection.

        // 5. Atomic rename under the write lock.
        //    Mirrors: let _swap = INDEX_WRITE_LOCK.lock(); fs::rename(&tmp, &paths.index_db)
        writeLock.lock()
        defer { writeLock.unlock() }

        if FileManager.default.fileExists(atPath: indexDBPath) {
            try FileManager.default.removeItem(atPath: indexDBPath)
        }
        try FileManager.default.moveItem(atPath: tmpPath, toPath: indexDBPath)

        // QUA-104: a stale entries.cache from before this rebuild may still
        // happen to carry a revision number equal to the new DB's
        // freshly-bumped revision (both could be 1 if entries_revision wraps
        // back to 0 after createSchema). Nuke the cache file so the next
        // loadEntries takes the SQL path once and writes a cache tied to the
        // new DB's revision.
        let cachePath = indexDBDir + "/entries.cache"
        try? FileManager.default.removeItem(atPath: cachePath)

        // 6. Flip to WAL so all subsequent readers can open concurrently.
        //    Mirrors: let _ = open_index_rw(&paths.index_db);
        //    DatabasePool opens in WAL mode automatically (it issues PRAGMA journal_mode=WAL).
        let _ = try DatabasePool(path: indexDBPath)
        // DatabasePool is intentionally dropped immediately — we just need the WAL flip.

        return entries.count
    }

    // MARK: - canSkipFullBuild

    /// Returns true iff the live index exists and its schema is current — i.e.
    /// `reconcile()` would take the fast delta path, not the buildFull fallback.
    /// Used by boot to decide whether the UI can be shown from the existing
    /// index immediately while reconcile runs in the background.
    public func canSkipFullBuild() -> Bool {
        guard FileManager.default.fileExists(atPath: indexDBPath) else { return false }
        return (try? indexSchemaCurrent()) ?? false
    }

    // MARK: - reconcile

    /// Delta sync. Self-healing: if the index is missing or the schema is stale,
    /// falls back to `buildFull`. Otherwise diffs mtimes: upserts new/modified
    /// entries, deletes vanished ones, counts unchanged.
    ///
    /// Mirrors `reconcile_index` (:350-425).
    public func reconcile() throws -> ReconcileStats {
        // No index → full build (mirrors :353-360).
        guard FileManager.default.fileExists(atPath: indexDBPath) else {
            let count = try buildFull()
            return ReconcileStats(upserted: count, removed: 0, unchanged: 0)
        }

        // Schema stale → full build (mirrors :361-368).
        guard try indexSchemaCurrent() else {
            let count = try buildFull()
            return ReconcileStats(upserted: count, removed: 0, unchanged: 0)
        }

        // Current vault fingerprints: rel → mtime ms (mirrors :372-380).
        let sourceSlugs = loadSourceSlugs(sourcesDir: sourcesPath)
        let sourceIndex = SourceSlugIndex(sourceSlugs)
        let files = try walkMarkdown(vaultPath)
        var fsMap = [String: Int64](minimumCapacity: files.count)
        for file in files {
            let rel = slashRelative(root: workspaceRoot, path: file)
            if let mt = Self.mtimeMs(atPath: file) {
                fsMap[rel] = mt
            }
        }

        // Take the write lock for the entire delta (mirrors :382-424).
        writeLock.lock()
        defer { writeLock.unlock() }

        // Open the live DB in WAL mode (read-write needed for WAL shm access).
        var config = Configuration()
        config.label = "MarpleIndexer.reconcile"
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(path: indexDBPath, configuration: config)

        // Indexed fingerprints: path → mtime (nil means mtime column was NULL).
        let indexed: [String: Int64?] = try pool.read { db in
            var map = [String: Int64?]()
            let rows = try Row.fetchAll(db, sql: "SELECT path, mtime FROM entries")
            for row in rows {
                let path: String = row["path"]
                let mtime: Int64? = row["mtime"]
                map[path] = mtime
            }
            return map
        }

        var stats = ReconcileStats()
        var writes: [(rel: String, entry: IndexedEntry?)] = []

        // New or modified files: missing in index OR mtime differs → upsert (mirrors :401-413).
        for (rel, mt) in fsMap {
            if let indexedMtime = indexed[rel], indexedMtime == mt {
                stats.unchanged += 1
                continue
            }

            let existing = indexed.keys.contains(rel)
            let absPath = workspaceRoot + "/" + rel
            if let entry = indexedEntryForPath(
                sourceSlugs: sourceSlugs,
                sourceIndex: sourceIndex,
                absPath: absPath,
                rel: rel
            ) {
                writes.append((rel: rel, entry: entry))
                stats.upserted += 1
            } else if existing {
                writes.append((rel: rel, entry: nil))
                stats.removed += 1
            }
        }

        // Vanished files: in index but not on disk → delete rows (mirrors :416-422).
        for rel in indexed.keys where fsMap[rel] == nil {
            writes.append((rel: rel, entry: nil))
            stats.removed += 1
        }

        // QUA-104: row changes and entries_revision must commit atomically, otherwise
        // a matching old entries.cache can hide newly indexed rows from loadEntries().
        if !writes.isEmpty {
            try pool.write { db in
                for write in writes {
                    try deletePathRows(db, rel: write.rel)
                    if let entry = write.entry {
                        try IndexWriter.insert(db, entry)
                    }
                }
                try IndexWriter.bumpEntriesRevision(db)
            }
        }

        return stats
    }

    // MARK: - Private helpers

    // MARK: walkMarkdown

    /// Recursively collect `.md` files under `dir`, skipping any entry whose
    /// name starts with `.`. Mirrors `walk_markdown` (:610-628).
    private func walkMarkdown(_ dir: String) throws -> [String] {
        var result = [String]()
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return result
        }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            // Skip any entry whose name starts with '.' (mirrors :614 in Rust).
            if name.hasPrefix(".") {
                // Also skip descending into dot-directories.
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Collect .md files (regular or symlink).
            let rsrc = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let isFile = (rsrc?.isRegularFile ?? false) || (rsrc?.isSymbolicLink ?? false)
            if isFile && url.pathExtension == "md" {
                result.append(url.path)
            }
        }

        // Mirror the Rust `files.sort()` call so order is deterministic.
        result.sort()
        return result
    }

    // MARK: slashRelative

    /// Strip `root + "/"` from `path` and return the remainder.
    /// Mirrors `slash_relative` in indexer.rs (:1151-1158).
    ///
    /// Resolve symlinks on the ROOT only — e.g. `/var` → `/private/var`, the form
    /// `FileManager.enumerator` returns — then strip that prefix from the literal
    /// file path. We must NOT resolve symlinks on the file path: a symlinked `.md`
    /// would collapse onto its target so two walked files would yield the same
    /// workspace-relative path and crash the insert (UNIQUE constraint). Rust's
    /// `slash_relative` strips the literal prefix without resolving either side.
    private func slashRelative(root: String, path: String) -> String {
        // macOS firmlinks: /var, /tmp, /etc are symlinks to /private/var etc.
        // FileManager.enumerator returns the /private form while the workspace
        // root may be in either form. Normalize a leading "/private" off BOTH
        // sides so the prefix compares consistently — WITHOUT resolving symlinks
        // inside the path (resolving would collapse a symlinked .md onto its
        // target, producing a duplicate workspace-relative path and crashing the
        // bulk insert). Rust's slash_relative strips a literal prefix; this is the
        // same, made robust to the firmlink form difference.
        func stripPrivate(_ p: String) -> String {
            p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
        }
        let r = stripPrivate(root)
        let p = stripPrivate(path)
        let prefix = r.hasSuffix("/") ? r : r + "/"
        if p.hasPrefix(prefix) {
            return String(p.dropFirst(prefix.count))
        }
        return p
    }

    // MARK: mtimeMs

    /// Epoch milliseconds of the file's modification date, or nil.
    /// Mirrors `mtime_ms` (:1145-1149).
    static func mtimeMs(atPath path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date
        else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: indexSchemaCurrent

    /// Returns true iff the live index exists, has all REQUIRED columns AND no
    /// retired tables. Returning false here forces `reconcile()` to fall back
    /// to `buildFull`, which is how QUA-102 migrates an existing 1.4 GB DB
    /// (with `entry_search` / `entry_text`) down to the current ~750 MB shape.
    private func indexSchemaCurrent() throws -> Bool {
        guard FileManager.default.fileExists(atPath: indexDBPath) else { return false }

        // Required `entries` columns: missing any of these → schema predates
        // the second translation/PDF metadata expansion.
        let required: Set<String> = [
            "title_en", "title_cn", "kind", "journal", "publisher", "isbn", "category",
            "translation_title_cn", "translation_douban_url",
            // QUA-137: topics_json replaced the dropped singular `topic` column.
            // Its absence means a pre-0.4.0 DB → force buildFull rebuild.
            "topics_json",
            // QUA-185: `media` carries talk's recording filename for conformance.
            // Its absence means a pre-QUA-185 DB → force buildFull rebuild.
            "media",
            // QUA-175: `width`/`height`/`file_size` carry image technical
            // fields derived from original.<ext>. Absence → rebuild.
            "width",
        ]

        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        // Use DatabasePool — a read-only DatabaseQueue cannot attach the WAL
        // -shm on a closed-writer DB (CANTOPEN). See IndexDatabase for the same
        // reason.
        let pool = try DatabasePool(path: indexDBPath, configuration: config)
        return try pool.read { db in
            var columns = Set<String>()
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(entries)")
            for row in rows {
                if let name: String = row["name"] {
                    columns.insert(name)
                }
            }
            guard required.isSubset(of: columns) else { return false }

            // QUA-102 schema bump: presence of `entry_search` (the dropped
            // 12-column FTS5 table) means this DB was built by an older marple
            // and is now ~660 MB heavier than necessary. Trigger a full rebuild.
            let hasRetiredEntrySearch = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                  SELECT 1 FROM sqlite_master
                  WHERE type IN ('table','view') AND name = 'entry_search'
                )
                """) ?? false
            return !hasRetiredEntrySearch
        }
    }

    // MARK: deletePathRows

    /// Delete all rows for `rel` across the 3 tables we write to.
    private func deletePathRows(_ db: Database, rel: String) throws {
        try db.execute(sql: "DELETE FROM entries WHERE path = ?",      arguments: [rel])
        try db.execute(sql: "DELETE FROM entry_themes WHERE path = ?", arguments: [rel])
        try db.execute(sql: "DELETE FROM entry_trigram WHERE path = ?",arguments: [rel])
    }

    // MARK: indexedEntryForPath

    /// Parse `rel` for a reconcile upsert. `added` remains 0 here, matching Rust
    /// behaviour (only `buildFull` sets it from git dates).
    private func indexedEntryForPath(
        sourceSlugs: Set<String>,
        sourceIndex: SourceSlugIndex,
        absPath: String,
        rel: String
    ) -> IndexedEntry? {
        guard let text = try? String(contentsOfFile: absPath, encoding: .utf8) else {
            return nil
        }
        let fileStem = URL(fileURLWithPath: absPath).deletingPathExtension().lastPathComponent
        let mtimeMs  = Self.mtimeMs(atPath: absPath)

        let outcome = buildIndexedEntry(
            text: text,
            rel: rel,
            fileStem: fileStem,
            sourceSlugs: sourceSlugs,
            mtimeMs: mtimeMs,
            sourceIndex: sourceIndex,
            schema: schema
        )

        if case .indexed(var entry) = outcome {
            Self.deriveImageFields(&entry, absPath: absPath)
            return entry
        }
        return nil
    }

    // MARK: deriveImageFields

    /// Fill an image entry's technical fields (width / height / file size)
    /// from its sibling `original.<ext>` (QUA-175). No-op for other types.
    private static func deriveImageFields(_ entry: inout IndexedEntry, absPath: String) {
        guard entry.entryType == "image",
              let dims = ImageProbe.probe(imageEntryAbsPath: absPath) else { return }
        entry.width = dims.width
        entry.height = dims.height
        entry.fileSize = dims.fileSize
    }
}
