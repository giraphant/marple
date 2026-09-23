import Foundation

/// Folder-backed groups. Only direct children of vault/archives may be groups;
/// neither a group manifest nor a second membership list is stored.
public struct ArchiveCollection: Codable, Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let members: [String]
}

public struct ArchiveCollectionInventory: Codable, Equatable, Sendable {
    public let collections: [ArchiveCollection]
    public let ungrouped: [String]
    public let issues: [String]
}

public struct ArchiveCollectionCommand: Codable, Equatable, Sendable {
    public let action: String
    public var paths: [String]
    public var destination: String?
    public var name: String?
    public var dryRun: Bool
    public var requestID: String?

    public init(action: String, paths: [String] = [], destination: String? = nil,
                name: String? = nil, dryRun: Bool = false, requestID: String? = nil) {
        self.action = action; self.paths = paths; self.destination = destination
        self.name = name; self.dryRun = dryRun; self.requestID = requestID
    }
}

public struct ArchiveCollectionChange: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    public func remap(_ path: String) -> String {
        path == from ? to : path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
    }
}

public struct ArchiveCollectionResult: Codable, Sendable {
    public var replayed: Bool = false
    public let inventory: ArchiveCollectionInventory
    public let moves: [ArchiveCollectionChange]
    public let updatedReferences: [String]
    public let dryRun: Bool
    public let requestID: String?
}

public struct ArchiveCollectionError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let description: String
    public init(_ code: String, _ description: String) { self.code = code; self.description = description }
}

public struct ArchiveCollections: Sendable {
    public static let base = "vault/archives"
    public let workspaceRoot: String
    public init(workspaceRoot: String) { self.workspaceRoot = workspaceRoot }
    var root: URL { URL(fileURLWithPath: workspaceRoot).standardizedFileURL.resolvingSymlinksInPath() }
    var baseURL: URL { root.appendingPathComponent(Self.base) }

    /// Accept absolute or workspace-relative paths, but never links or traversal.
    func checkedURL(_ path: String) throws -> URL {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        var normalized = url.standardizedFileURL.path
        // FileManager may return physical /private paths for macOS firmlinks.
        for prefix in ["/private/tmp/", "/private/var/", "/private/etc/"] where normalized.hasPrefix(prefix) {
            normalized = String(normalized.dropFirst("/private".count))
        }
        let clean = URL(fileURLWithPath: normalized).standardizedFileURL
        guard !path.split(separator: "/").contains(".."),
              clean.path == baseURL.path || clean.path.hasPrefix(baseURL.path + "/"),
              clean.resolvingSymlinksInPath().path == clean.path else {
            throw ArchiveCollectionError("invalid_path", "Path must stay inside vault/archives without symbolic links: \(path)")
        }
        return clean
    }
    func relative(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/") }
    func regular(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    func directories(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { item in
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    public func inventory() throws -> ArchiveCollectionInventory {
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return .init(collections: [], ungrouped: [], issues: [])
        }
        _ = try checkedURL(Self.base)
        var collections: [ArchiveCollection] = [], ungrouped: [String] = [], issues: [String] = []
        for directory in try directories(baseURL) {
            let archive = regular(directory.appendingPathComponent("archive.md"))
            let collection = regular(directory.appendingPathComponent("collection.md"))
            if archive && collection {
                issues.append("Ambiguous Archive/Collection: \(relative(directory))"); continue
            }
            if archive { ungrouped.append(relative(directory.appendingPathComponent("archive.md"))); continue }
            guard collection else { continue }
            var members: [String] = []
            for child in try directories(directory) {
                if regular(child.appendingPathComponent("collection.md")) {
                    issues.append("Nested collection is unsupported: \(relative(child))")
                } else if regular(child.appendingPathComponent("archive.md")) {
                    members.append(relative(child.appendingPathComponent("archive.md")))
                }
            }
            let text = try String(contentsOf: directory.appendingPathComponent("collection.md"), encoding: .utf8)
            let title = Frontmatter.split(text).body.split(separator: "\n").first { $0.hasPrefix("# ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
            collections.append(.init(path: relative(directory), title: title?.isEmpty == false ? title! : directory.lastPathComponent, members: members))
        }
        let pages = ungrouped + collections.flatMap(\.members)
        let slugs = Dictionary(grouping: pages, by: { ($0 as NSString).deletingLastPathComponent.components(separatedBy: "/").last!.lowercased() })
        for (slug, paths) in slugs where paths.count > 1 { issues.append("Duplicate Archive slug: \(slug)") }
        return .init(collections: collections, ungrouped: ungrouped, issues: issues)
    }
    func validateName(_ name: String?) throws -> String {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !value.hasPrefix("."), !value.contains("/"), !value.contains(":"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveCollectionError("invalid_name", "A collection needs a nonempty, single directory name")
        }
        return value
    }
}
