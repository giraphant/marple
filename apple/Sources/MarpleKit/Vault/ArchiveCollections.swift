import Foundation

/// A collection is a single optional frontmatter value, independent of file location.
/// `path` is retained as the wire identifier; its value is now the collection name.
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
    public var fields: [String: [String: [String]]]? = nil
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
            return .init(collections: [], ungrouped: [], issues: [], fields: [:])
        }
        _ = try checkedURL(Self.base)
        var metadata: [String: [String: [String]]] = [:]
        var issues: [String] = []
        // Read legacy nested archives too. Directory names and collection.md never
        // contribute membership; only each archive's own collection field does.
        func visit(_ directory: URL) throws {
            let archive = directory.appendingPathComponent("archive.md")
            if regular(archive) {
                let raw = try String(contentsOf: archive, encoding: .utf8)
                let pairs = YamlFrontmatter.parseMapping(Frontmatter.split(raw).frontmatter ?? "")
                let path = relative(archive)
                var fields: [String: [String]] = [:]
                for (key, value) in pairs {
                    if key == "collection" {
                        switch value {
                        case .string, .null: break
                        default:
                            issues.append("collection must be a single text value: \(path)")
                            continue
                        }
                    }
                    fields[key] = ArchiveFieldGroup.values(value)
                }
                metadata[path] = fields
                return
            }
            for child in try directories(directory) where child.lastPathComponent != "originals" {
                try visit(child)
            }
        }
        try visit(baseURL)
        var members: [String: [String]] = [:], ungrouped: [String] = []
        for path in metadata.keys.sorted() {
            if let name = metadata[path]?["collection"]?.first { members[name, default: []].append(path) }
            else { ungrouped.append(path) }
        }
        let collections = members.keys.sorted().map {
            ArchiveCollection(path: $0, title: $0, members: members[$0]!)
        }
        return .init(collections: collections, ungrouped: ungrouped, issues: issues, fields: metadata)
    }
    func validateName(_ name: String?) throws -> String {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveCollectionError("invalid_name", "A collection needs a nonempty, single-line name")
        }
        return value
    }
}
