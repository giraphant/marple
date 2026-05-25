import Foundation

public enum VaultError: Error, Equatable {
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
    /// Open the source PDF for `slug` (resolves sources/<stem>.pdf, exact-or-fuzzy).
    func openSourcePDF(slug: String) async throws
    /// Open the translated PDF (processing/translations/<slug>-zh.pdf).
    func openTranslatedPDF(slug: String) async throws
    /// Whether a translated PDF exists for `slug` (gates the 打开译本 affordance).
    func hasTranslatedPDF(slug: String) -> Bool
    func writeFile(path: String, text: String) async throws
    func createNote(path: String, text: String) async throws
    func moveToTrash(path: String) async throws -> String
    func listTrash() async throws -> [TrashItem]
    func restoreTrash(name: String) async throws -> String
    func purgeTrash(name: String) async throws
}

/// Records the last write so stub-backed tests can assert on it.
public final class WriteLog: @unchecked Sendable {
    public private(set) var last: (path: String, text: String)?
    public init() {}
    public func record(_ path: String, _ text: String) { last = (path, text) }
}

/// Records created notes so stub-backed tests can assert on them.
public final class CreateLog: @unchecked Sendable {
    public private(set) var created: [(path: String, text: String)] = []
    public init() {}
    public func record(_ path: String, _ text: String) { created.append((path, text)) }
}

/// In-memory trash for the stub: seeded items + a log of operations.
public final class TrashStore: @unchecked Sendable {
    public private(set) var items: [TrashItem]
    public private(set) var moved: [String] = []
    public private(set) var restored: [String] = []
    public private(set) var purged: [String] = []
    public init(_ items: [TrashItem] = []) { self.items = items }
    public func move(_ path: String) { moved.append(path) }
    public func restore(_ name: String) { restored.append(name); items.removeAll { $0.name == name } }
    public func purge(_ name: String) { purged.append(name); items.removeAll { $0.name == name } }
}

public struct StubVaultClient: VaultClient {
    public let entries: [Entry]
    public let texts: [String: String]
    public let hits: [SearchHit]
    public let writeLog = WriteLog()
    public let createLog = CreateLog()
    public let trash: TrashStore
    public init(entries: [Entry], texts: [String: String], hits: [SearchHit] = [],
                trashItems: [TrashItem] = []) {
        self.entries = entries; self.texts = texts; self.hits = hits
        self.trash = TrashStore(trashItems)
    }
    public func index() async throws -> [Entry] { entries }
    public func entryText(path: String) async throws -> String {
        guard let t = texts[path] else { throw VaultError.notFound(path) }
        return t
    }
    public func search(_ query: SearchQuery) async throws -> [SearchHit] { hits }
    public func openInEditor(path: String, app: String) async throws {}
    public func openSourcePDF(slug: String) async throws {}
    public func openTranslatedPDF(slug: String) async throws {}
    public func hasTranslatedPDF(slug: String) -> Bool { false }
    public func writeFile(path: String, text: String) async throws { writeLog.record(path, text) }
    public func createNote(path: String, text: String) async throws { createLog.record(path, text) }
    public func moveToTrash(path: String) async throws -> String {
        trash.move(path); return "vault/notes/.trash/stub.md"
    }
    public func listTrash() async throws -> [TrashItem] { trash.items }
    public func restoreTrash(name: String) async throws -> String {
        trash.restore(name); return "vault/notes/\(name)"
    }
    public func purgeTrash(name: String) async throws { trash.purge(name) }
}
