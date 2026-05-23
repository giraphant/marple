import Foundation

public enum VaultError: Error, Equatable {
    case backendUnavailable
    case http(status: Int, body: String)
    case notFound(String)
    case decode(String)
}

public struct SearchQuery: Sendable, Equatable {
    public var q: String
    public var type: EntryType?
    public var minRating: Double?
    public var theme: String?
    public var limit: Int
    public init(q: String, type: EntryType? = nil, minRating: Double? = nil,
                theme: String? = nil, limit: Int = 80) {
        self.q = q; self.type = type; self.minRating = minRating
        self.theme = theme; self.limit = limit
    }
}

public struct SearchHit: Sendable, Equatable, Identifiable, Decodable {
    public let entry: Entry
    public let score: Double
    public let snippet: String?
    public let source: String
    public var id: String { entry.path }
    public init(entry: Entry, score: Double, snippet: String?, source: String) {
        self.entry = entry; self.score = score; self.snippet = snippet; self.source = source
    }
}

public protocol VaultClient: Sendable {
    func index() async throws -> [Entry]
    func entryText(path: String) async throws -> String
    func search(_ query: SearchQuery) async throws -> [SearchHit]
    func openInEditor(path: String, app: String) async throws
}

public struct StubVaultClient: VaultClient {
    public let entries: [Entry]
    public let texts: [String: String]
    public let hits: [SearchHit]
    public init(entries: [Entry], texts: [String: String], hits: [SearchHit] = []) {
        self.entries = entries; self.texts = texts; self.hits = hits
    }
    public func index() async throws -> [Entry] { entries }
    public func entryText(path: String) async throws -> String {
        guard let t = texts[path] else { throw VaultError.notFound(path) }
        return t
    }
    public func search(_ query: SearchQuery) async throws -> [SearchHit] { hits }
    public func openInEditor(path: String, app: String) async throws {}
}
