import Foundation

public enum VaultError: Error, Equatable {
    case backendUnavailable
    case http(status: Int, body: String)
    case notFound(String)
    case decode(String)
}

public protocol VaultClient: Sendable {
    func index() async throws -> [Entry]
    func entryText(path: String) async throws -> String
    func openInEditor(path: String, app: String) async throws
}

public struct StubVaultClient: VaultClient {
    public let entries: [Entry]
    public let texts: [String: String]
    public init(entries: [Entry], texts: [String: String]) {
        self.entries = entries; self.texts = texts
    }
    public func index() async throws -> [Entry] { entries }
    public func entryText(path: String) async throws -> String {
        guard let t = texts[path] else { throw VaultError.notFound(path) }
        return t
    }
    public func openInEditor(path: String, app: String) async throws {}
}
