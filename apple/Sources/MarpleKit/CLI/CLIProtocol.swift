import Foundation

// Wire protocol for marple-cli (QUA-107). Shared by the client (marple-cli)
// and the server (CLIServer inside Marple.app). The transport is a Unix domain
// socket at ~/Library/Application Support/Marple/cli.sock, framed as NDJSON:
// one CLIRequest per line, one CLIResponse per line, then the connection closes.
//
// The Request schema is intentionally loose (flat optionals dispatched by
// `method`) so it's trivial for an AI agent to construct without touching
// Swift-flavoured tagged unions, and so adding a method only adds fields.

/// Single-method JSON-RPC-flavoured request.
public struct CLIRequest: Codable, Sendable {
    public let method: String
    public let path: String?
    public let query: String?
    public let limit: Int?
    public let id: String?
    public let ids: [String]?
    public let title: String?
    public let reset: Bool?
    public let parent: String?
    public let before: String?
    public let after: String?
    public let root: Bool?
    public let operation: String?
    public let requestID: String?
    public let retryOnly: Bool?

    public init(method: String,
                path: String? = nil,
                query: String? = nil,
                limit: Int? = nil,
                id: String? = nil, ids: [String]? = nil,
                title: String? = nil, reset: Bool? = nil,
                parent: String? = nil, before: String? = nil,
                after: String? = nil, root: Bool? = nil,
                operation: String? = nil, requestID: String? = nil, retryOnly: Bool? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.limit = limit
        self.id = id
        self.ids = ids
        self.title = title
        self.reset = reset
        self.parent = parent
        self.before = before
        self.after = after
        self.root = root
        self.operation = operation
        self.requestID = requestID
        self.retryOnly = retryOnly
    }

    /// The separate method makes older servers reject before applying a write.
    public func asMutation(requestID: String, retryOnly: Bool) -> CLIRequest {
        CLIRequest(method: CLIMethod.mutate, path: path, query: query, limit: limit,
                   id: id, ids: ids, title: title, reset: reset, parent: parent,
                   before: before, after: after, root: root,
                   operation: method, requestID: requestID, retryOnly: retryOnly)
    }

    public var organizationMethod: String { method == CLIMethod.mutate ? (operation ?? "") : method }
}

public enum CLIMethod {
    public static let mutate = "mutate"
    public static let search = "search"
    public static let read = "read"
    public static let open = "open"
    public static let ping = "ping"
    public static let tabsList = "tabs.list"
    public static let tabsRename = "tabs.rename"
    public static let tabsMove = "tabs.move"
    public static let foldersCreate = "folders.create"
    public static let foldersRename = "folders.rename"
    public static let foldersMove = "folders.move"
    public static let foldersDissolve = "folders.dissolve"

    public static func isOrganizationMutation(_ method: String) -> Bool {
        [tabsRename, tabsMove, foldersCreate, foldersRename, foldersMove, foldersDissolve].contains(method)
    }
}

public struct CLIResponse: Codable, Sendable {
    public let ok: Bool
    public let data: CLIResponseData?
    public let error: CLIError?
    public let requestID: String?

    public init(ok: Bool, data: CLIResponseData? = nil, error: CLIError? = nil, requestID: String? = nil) {
        self.ok = ok
        self.data = data
        self.error = error
        self.requestID = requestID
    }

    public func identified(by requestID: String?) -> CLIResponse {
        CLIResponse(ok: ok, data: data, error: error, requestID: requestID)
    }

    public static func success(_ data: CLIResponseData? = nil) -> CLIResponse {
        CLIResponse(ok: true, data: data, error: nil)
    }

    public static func failure(code: String, message: String) -> CLIResponse {
        CLIResponse(ok: false, data: nil, error: CLIError(code: code, message: message))
    }
}

public struct CLIError: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code; self.message = message
    }
}

public enum CLIErrorCode {
    public static let notRunning = "marple_not_running"
    public static let badRequest = "bad_request"
    public static let notFound = "not_found"
    public static let internalError = "internal_error"
}

/// All optional — populated per method. Loose by design so the wire format
/// stays one JSON object per line without union-tagging overhead.
public struct CLIResponseData: Codable, Sendable {
    public let entries: [EntryDigest]?
    public let entry: EntryDetail?
    public let opened: Bool?
    public let pong: String?
    public let tree: [CLITabNode]?
    public let spaceID: UUID?
    public let activeTabID: UUID?
    public let createdID: UUID?

    public init(entries: [EntryDigest]? = nil,
                entry: EntryDetail? = nil,
                opened: Bool? = nil,
                pong: String? = nil,
                tree: [CLITabNode]? = nil, spaceID: UUID? = nil,
                activeTabID: UUID? = nil, createdID: UUID? = nil) {
        self.entries = entries
        self.entry = entry
        self.opened = opened
        self.pong = pong
        self.tree = tree
        self.spaceID = spaceID
        self.activeTabID = activeTabID
        self.createdID = createdID
    }
}

/// A sidebar node. `path` identifies the pinned page; `currentPath` is its
/// current reading location, which may differ after following a link.
public struct CLITabNode: Codable, Sendable {
    public let id: UUID
    public let kind: String
    public let title: String
    public let path: String?
    public let currentPath: String?
    public let pinned: Bool?
    public let children: [CLITabNode]?

    public init(id: UUID, kind: String, title: String, path: String? = nil,
                currentPath: String? = nil, pinned: Bool? = nil, children: [CLITabNode]? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.currentPath = currentPath
        self.pinned = pinned
        self.children = children
    }
}

/// Light projection of `Entry` — what list/search need without dragging derived
/// caches across the wire. `type` is the raw EntryType rawValue: one of the
/// canonical Quasi short forms `paper / book / chapter / author / topic /
/// journal / note / image`, or any unknown raw string preserved as-is for
/// `.other(_)` entries (QUA-119).
public struct EntryDigest: Codable, Sendable {
    public let path: String
    public let title: String?
    public let type: String
    public let themes: [String]
    public let author: [String]
    public let year: String?
    public let mtime: Double?

    public init(path: String, title: String?, type: String, themes: [String],
                author: [String], year: String?, mtime: Double?) {
        self.path = path; self.title = title; self.type = type
        self.themes = themes; self.author = author; self.year = year
        self.mtime = mtime
    }
}

/// Full read result: digest + raw frontmatter (as it sits in the file) + body.
public struct EntryDetail: Codable, Sendable {
    public let digest: EntryDigest
    public let frontmatter: String   // raw YAML block, "" if the file has none
    public let body: String          // file contents below the frontmatter

    public init(digest: EntryDigest, frontmatter: String, body: String) {
        self.digest = digest; self.frontmatter = frontmatter; self.body = body
    }
}

/// Canonical socket path under user's Application Support. Server creates the
/// directory if missing; client connects to the same path.
public enum CLISocket {
    public static func defaultPath() -> String {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #else
        // iOS never runs the CLI socket; this just needs to compile.
        let home = NSHomeDirectory()
        #endif
        return home + "/Library/Application Support/Marple/cli.sock"
    }
}
