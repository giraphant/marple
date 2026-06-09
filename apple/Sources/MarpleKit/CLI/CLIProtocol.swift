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

    public init(method: String,
                path: String? = nil,
                query: String? = nil,
                limit: Int? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.limit = limit
    }
}

public enum CLIMethod {
    public static let search = "search"
    public static let read = "read"
    public static let open = "open"
    public static let ping = "ping"
}

public struct CLIResponse: Codable, Sendable {
    public let ok: Bool
    public let data: CLIResponseData?
    public let error: CLIError?

    public init(ok: Bool, data: CLIResponseData? = nil, error: CLIError? = nil) {
        self.ok = ok
        self.data = data
        self.error = error
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

    public init(entries: [EntryDigest]? = nil,
                entry: EntryDetail? = nil,
                opened: Bool? = nil,
                pong: String? = nil) {
        self.entries = entries
        self.entry = entry
        self.opened = opened
        self.pong = pong
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
