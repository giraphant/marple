import Foundation
import Testing
@testable import MarpleKit

@MainActor @Suite struct MetadataWriterTests {
    @Test func writeFetchesTransformsAndPersists() async throws {
        let client = MemoryVaultClient(texts: ["vault/papers/p.md": "title: P"])
        let writer = MetadataWriter(client: client)
        try await writer.write(path: "vault/papers/p.md", applying: { $0 + "\nrating: ★★★" })
        let after = try await client.entryText(path: "vault/papers/p.md")
        #expect(after.contains("rating: ★★★"))
    }

    @Test func writeAppliesTransformToFreshDiskText() async throws {
        // pins "fetch FRESH text then transform" ordering (not a stale snapshot)
        let client = MemoryVaultClient(texts: ["p": "A"])
        let writer = MetadataWriter(client: client)
        try await writer.write(path: "p", applying: { $0 + "B" })
        #expect(try await client.entryText(path: "p") == "AB")
    }

    @Test func writePropagatesClientError() async {
        // entryText throws VaultError.notFound for an unknown path → must propagate.
        let client = MemoryVaultClient(texts: [:])
        let writer = MetadataWriter(client: client)
        await #expect(throws: (any Error).self) {
            try await writer.write(path: "missing", applying: { $0 })
        }
    }
}

/// Minimal VaultClient test double that actually persists writes back into its
/// in-memory store, so a write can be read back (StubVaultClient only logs writes).
private final class MemoryVaultClient: VaultClient, @unchecked Sendable {
    private var texts: [String: String]
    init(texts: [String: String]) { self.texts = texts }

    func entryText(path: String) async throws -> String {
        guard let t = texts[path] else { throw VaultError.notFound(path) }
        return t
    }
    func writeFile(path: String, text: String) async throws { texts[path] = text }

    // Unreachable by MetadataWriter.write (entryText/writeFile only). Trap loudly so
    // a future test that accidentally routes through one fails instead of getting a
    // garbage sentinel.
    func index() async throws -> [Entry] { fatalError("unused in MetadataWriterTests") }
    func search(_ query: SearchQuery) async throws -> [SearchHit] { fatalError("unused in MetadataWriterTests") }
    func openInEditor(path: String, app: String) async throws { fatalError("unused in MetadataWriterTests") }
    func openPDF(slug: String) async throws { fatalError("unused in MetadataWriterTests") }
    func openTranslation(slug: String) async throws { fatalError("unused in MetadataWriterTests") }
    func hasTranslation(slug: String) -> Bool { fatalError("unused in MetadataWriterTests") }
    func imageOriginalURL(forImageEntryPath path: String) async throws -> URL? { fatalError("unused in MetadataWriterTests") }
    func fileURL(for path: String) -> URL? { fatalError("unused in MetadataWriterTests") }
    func createImageObject(from sourceURL: URL, title: String?) async throws -> Entry { fatalError("unused in MetadataWriterTests") }
    func createNote(path: String, text: String) async throws { fatalError("unused in MetadataWriterTests") }
    func moveToTrash(path: String) async throws -> String { fatalError("unused in MetadataWriterTests") }
    func listTrash() async throws -> [TrashItem] { fatalError("unused in MetadataWriterTests") }
    func restoreTrash(name: String) async throws -> String { fatalError("unused in MetadataWriterTests") }
    func purgeTrash(name: String) async throws { fatalError("unused in MetadataWriterTests") }
}
