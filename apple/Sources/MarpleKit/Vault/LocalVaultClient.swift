import Foundation
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)
/// In-process `VaultClient`: reads/writes vault markdown files directly and
/// delegates metadata/search to `IndexDatabase`. No HTTP, no sidecar on the hot
/// path. All `path` arguments are workspace-relative (e.g. "vault/papers/x.md").
public struct LocalVaultClient: VaultClient {
    private let workspaceRoot: String
    private let indexDB: IndexDatabase

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
        let url = absURL(path)
        #if canImport(AppKit)
        let appName = app.trimmingCharacters(in: .whitespaces)
        if appName.isEmpty {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
            return
        }
        // Honor a specific editor via `open -a <app> <path>`.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", appName, url.path]
        try proc.run()
        #endif
    }

    public func openPDF(slug: String) async throws {
        let url = absURL("sources/\(slug).pdf")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.notFound("sources/\(slug).pdf")
        }
        #if canImport(AppKit)
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
        #endif
    }

    public func openTranslation(slug: String) async throws {
        let url = absURL("processing/translations/\(slug)-zh.pdf")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.notFound("processing/translations/\(slug)-zh.pdf")
        }
        #if canImport(AppKit)
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
        #endif
    }

    public func hasTranslation(slug: String) -> Bool {
        let url = absURL("processing/translations/\(slug)-zh.pdf")
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func fileURL(for path: String) -> URL? { absURL(path) }

    public func talkMediaURL(forEntryPath path: String) -> URL? {
        let dir = absURL(path).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let file = TalkMedia.mediaFilename(among: names) else { return nil }
        return dir.appendingPathComponent(file)
    }

    public func talkSubtitlesURL(forEntryPath path: String) -> URL? {
        let dir = absURL(path).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let file = TalkMedia.subtitlesFilename(among: names) else { return nil }
        return dir.appendingPathComponent(file)
    }

    public func imageOriginalURL(forImageEntryPath path: String) async throws -> URL? {
        let dir = absURL(path).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let rel = ImageAsset.originalPath(forImageEntryPath: path, existingFilenames: names) else { return nil }
        return absURL(rel)
    }

    public func createImageObject(from sourceURL: URL, title requestedTitle: String?) async throws -> Entry {
        let ext = sourceURL.pathExtension.lowercased()
        guard ImageAsset.isSupportedImageURL(sourceURL) else {
            throw VaultError.decode("unsupported image extension: \(ext)")
        }
        let title = Self.imageTitle(requestedTitle, fallback: sourceURL.deletingPathExtension().lastPathComponent)
        let slug = uniqueImageSlug(ImageAsset.slug(fromTitle: title))
        let relDir = "vault/images/\(slug)"
        let dir = absURL(relDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: dir.appendingPathComponent("\(ImageAsset.originalStem).\(ext)"))
        let metadata = FrontmatterPatch.setScalar("---\ntype: image\n---\n\n", key: "title", value: title)
        try metadata.write(to: dir.appendingPathComponent("image.md"), atomically: true, encoding: .utf8)
        return Entry(path: "\(relDir)/image.md", type: .image, title: title, author: [], year: nil,
                     ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }

    private func uniqueImageSlug(_ base: String) -> String {
        var slug = base
        var n = 2
        while FileManager.default.fileExists(atPath: absURL("vault/images/\(slug)").path) {
            slug = "\(base)-\(n)"
            n += 1
        }
        return slug
    }

    private static func imageTitle(_ title: String?, fallback: String) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : fallback
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
#endif
