import Foundation
import Yams

/// Reader inventory for Quasi archives. Markdown owns display order; this list
/// owns provenance and collection order, including valid link-only archives.
public struct ArchiveManifest: Decodable, Equatable, Sendable {
    public struct Source: Decodable, Equatable, Sendable {
        public let url: String
        public let title: String?
        public var webURL: URL? {
            guard let value = URL(string: url), ["http", "https"].contains(value.scheme ?? ""),
                  value.host != nil else { return nil }
            return value
        }
    }

    public struct File: Decodable, Equatable, Sendable {
        public let path: String
        public let title: String
        public let description: String
        public let mediaType: String
        public let capturedAt: String
        public let size: Int64
        public let sha256: String
        public let url: String
        public let source: Source?

        enum CodingKeys: String, CodingKey {
            case path, title, description, size, sha256, url, source
            case mediaType = "media_type", capturedAt = "captured_at"
        }
    }

    public let schemaVersion: String
    public let source: Source
    public let files: [File]
    public let coverage: String

    enum CodingKeys: String, CodingKey {
        case source, files, coverage
        case schemaVersion = "schema_version"
    }

    public static func load(entryPath: String, workspaceRoot: String) throws -> ArchiveManifest? {
        guard !workspaceRoot.isEmpty else { return nil }
        let root = URL(fileURLWithPath: workspaceRoot).resolvingSymlinksInPath()
        let url = root.appendingPathComponent(entryPath).deletingLastPathComponent()
            .appendingPathComponent("manifest.yaml").resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let manifest = try YAMLDecoder().decode(Self.self, from: String(contentsOf: url, encoding: .utf8))
        guard manifest.schemaVersion == "quasi.archive.manifest/0.2",
              manifest.source.webURL != nil,
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              manifest.files.allSatisfy({
                  !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.path.range(of: #"^originals/[a-z0-9]+(?:-[a-z0-9]+)*\.[a-z0-9]+$"#, options: .regularExpression) != nil
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return manifest
    }

    public func file(for url: URL, entryPath: String, workspaceRoot: String) -> File? {
        files.first { localURL(for: $0, entryPath: entryPath, workspaceRoot: workspaceRoot) == url }
    }

    public func localURL(for file: File, entryPath: String, workspaceRoot: String) -> URL? {
        LocalAttachment.resolve(file.path, entryPath: entryPath, workspaceRoot: workspaceRoot,
                                mediaType: file.mediaType)
    }

    public func source(for file: File) -> Source { file.source ?? source }
}
