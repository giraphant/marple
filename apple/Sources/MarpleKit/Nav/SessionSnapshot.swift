import Foundation

/// One open document on the Mac, as published to the iOS companion. `path` is the
/// workspace-relative key (e.g. "vault/papers/foo.md") — identical across devices
/// because the vault contents match; only the absolute mount root differs, so iOS
/// resolves it against its own `entries` by path. `title` is the tab's *display*
/// label — the user's custom name (别名) when renamed, else the document title.
/// `type` is the `EntryType` rawValue (a String, not the enum) so a newer Mac
/// adding a type never breaks an older reader's decode.
public struct OpenDocSnapshot: Codable, Sendable, Identifiable, Equatable {
    public let path: String
    public let title: String
    public let type: String
    public var id: String { path }
    public init(path: String, title: String, type: String) {
        self.path = path
        self.title = title
        self.type = type
    }
}

/// One node of the Mac's 页面 (sidebar tab) forest, mirrored for iOS: either a
/// document leaf or a named, nestable group (folder). Recursive to any depth — this
/// is what carries the Mac's folder structure + group names across, not just a flat
/// tab list.
public indirect enum SessionNode: Codable, Sendable, Equatable {
    case doc(OpenDocSnapshot)
    case group(name: String, isCollapsed: Bool, children: [SessionNode])
}

/// What the Mac publishes about its open tabs — read-only, for the iOS companion's
/// "Mac 上打开的" list. Carries the full recursive forest (`roots`). Versioned and
/// decoded leniently (the whole file read is best-effort) so neither side chokes on
/// the other's format drift.
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public var version: Int
    public var updatedAtMs: Int64
    public var roots: [SessionNode]
    public var activePath: String?

    public init(version: Int = 2, updatedAtMs: Int64,
                roots: [SessionNode], activePath: String?) {
        self.version = version
        self.updatedAtMs = updatedAtMs
        self.roots = roots
        self.activePath = activePath
    }
}

public enum SessionFile {
    /// Lives at the workspace root, OUTSIDE `vault/` (the user's data, which we
    /// never write) and OUTSIDE `.marple/` (which the user may exclude from iCloud
    /// to save space) — so it keeps syncing even if the derived index is excluded.
    public static let relativePath = "session/open-tabs.json"

    public static func url(workspaceRoot: String) -> URL {
        URL(fileURLWithPath: workspaceRoot).appendingPathComponent(relativePath)
    }
}
