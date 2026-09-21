import Foundation
import UniformTypeIdentifiers

/// Local originals stay beside folder-based objects, or are linked from Markdown.
/// Only resolve existing files inside the workspace, including through symlinks.
public enum LocalAttachment {
    public enum PreviewKind { case image, pdf, webarchive, media, unsupported }

    public static func previewKind(_ url: URL, mediaType: String? = nil) -> PreviewKind {
        if let mime = mediaType?.lowercased().split(separator: ";").first.map(String.init) {
            if mime == "application/x-webarchive" || mime == "application/x-apple-webarchive" { return .webarchive }
            if mime.hasPrefix("image/") { return .image }
            if mime == "application/pdf" { return .pdf }
            if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return .media }
            // Some snapshot producers report a generic binary MIME.
            if url.pathExtension.lowercased() == "webarchive" { return .webarchive }
            return .unsupported
        }
        if url.pathExtension.lowercased() == "webarchive" { return .webarchive }
        if isMedia(url) { return .media }
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .pdf) { return .pdf }
        }
        return .unsupported
    }

    public static func isMedia(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "mp3", "m4a", "wav", "aif", "aiff", "aac", "caf"]
            .contains(url.pathExtension.lowercased())
    }

    public static func supports(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "webarchive" || isMedia(url) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .image)
    }

    public static func resolve(_ target: String, entryPath: String, workspaceRoot: String, mediaType: String? = nil) -> URL? {
        guard !workspaceRoot.isEmpty else { return nil }
        let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true).resolvingSymlinksInPath()
        let base = target.hasPrefix("vault/") || target.hasPrefix("sources/")
            ? root : root.appendingPathComponent(entryPath).deletingLastPathComponent()
        guard let parsed = URL(string: target, relativeTo: base)?.absoluteURL,
              parsed.isFileURL, (mediaType != nil || supports(parsed)),
              var components = URLComponents(url: parsed, resolvingAgainstBaseURL: true) else { return nil }
        components.fragment = nil
        components.query = nil
        guard let url = components.url?.standardizedFileURL.resolvingSymlinksInPath(),
              url.path.hasPrefix(root.path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    public static func companions(for entry: Entry, workspaceRoot: String) -> [URL] {
        let filename = (entry.path as NSString).lastPathComponent
        guard (entry.type == .webpage && filename == "webpage.md")
                || (entry.type == .archive && filename == "archive.md"),
              !workspaceRoot.isEmpty else { return [] }
        let directory = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(entry.path).deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { resolve($0.absoluteString, entryPath: entry.path, workspaceRoot: workspaceRoot) }
            .sorted {
                if ($0.lastPathComponent == "snapshot.webarchive") != ($1.lastPathComponent == "snapshot.webarchive") {
                    return $0.lastPathComponent == "snapshot.webarchive"
                }
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }
}
