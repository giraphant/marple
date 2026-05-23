import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// In-process `VaultClient`: reads/writes vault markdown files directly and
/// delegates metadata/search to `IndexDatabase`. No HTTP, no sidecar on the hot
/// path. All `path` arguments are workspace-relative (e.g. "vault/papers/x.md").
public struct LocalVaultClient: VaultClient {
    let workspaceRoot: String
    let indexDB: IndexDatabase

    public init(workspaceRoot: String, index: IndexDatabase) {
        self.workspaceRoot = workspaceRoot
        self.indexDB = index
    }

    private func absURL(_ relPath: String) -> URL {
        URL(fileURLWithPath: workspaceRoot).appendingPathComponent(relPath)
    }
    private var trashDir: URL { absURL("vault/notes/.trash") }

    // MARK: metadata + search (delegate)

    public func index() async throws -> [Entry] { try indexDB.loadEntries() }

    public func search(_ query: SearchQuery) async throws -> [SearchHit] {
        try indexDB.search(query.q, type: query.type, minRating: query.minRating,
                           theme: query.theme, limit: query.limit)
    }

    // MARK: file IO

    public func entryText(path: String) async throws -> String {
        do { return try String(contentsOf: absURL(path), encoding: .utf8) }
        catch { throw VaultError.notFound(path) }
    }

    public func writeFile(path: String, text: String) async throws {
        try text.write(to: absURL(path), atomically: true, encoding: .utf8)
    }

    public func createNote(path: String, text: String) async throws {
        let url = absURL(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func openInEditor(path: String, app: String) async throws {
        #if canImport(AppKit)
        let url = absURL(path)
        await MainActor.run { NSWorkspace.shared.open(url) }
        #endif
    }

    // MARK: trash (file moves under vault/notes/.trash, name = "{base}.{ts}.md")

    public func moveToTrash(path: String) async throws -> String {
        let fm = FileManager.default
        let src = absURL(path)
        guard fm.fileExists(atPath: src.path) else { throw VaultError.notFound(path) }
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let base = src.deletingPathExtension().lastPathComponent
        let name = "\(base).\(Self.trashTimestamp()).md"
        try fm.moveItem(at: src, to: trashDir.appendingPathComponent(name))
        return "vault/notes/.trash/\(name)"
    }

    public func listTrash() async throws -> [TrashItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: trashDir.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.map { name in
            let url = trashDir.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? Int) ?? 0
            let (base, ts) = Self.splitTrashName(name)
            return TrashItem(name: name, originalBase: base, ts: ts, mtime: mtime, size: size)
        }
    }

    public func restoreTrash(name: String) async throws -> String {
        let fm = FileManager.default
        let src = trashDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else { throw VaultError.notFound(name) }
        let (base, _) = Self.splitTrashName(name)
        let rel = "vault/notes/\(base ?? name).md"
        try fm.moveItem(at: src, to: absURL(rel))
        return rel
    }

    public func purgeTrash(name: String) async throws {
        let fm = FileManager.default
        let target = trashDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: target.path) else { throw VaultError.notFound(name) }
        try fm.removeItem(at: target)
    }

    // MARK: helpers

    /// Filesystem-safe, dot-free timestamp so `splitTrashName` can split on the
    /// last dot reliably.
    static func trashTimestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    /// "{base}.{ts}.md" -> (base, ts). Splits on the last dot of the stem so a
    /// base containing dots is preserved.
    static func splitTrashName(_ name: String) -> (base: String?, ts: String?) {
        let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        guard let dot = stem.lastIndex(of: ".") else { return (stem, nil) }
        return (String(stem[..<dot]), String(stem[stem.index(after: dot)...]))
    }
}
