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

    func index() async throws -> [Entry] { [] }
    func search(_ query: SearchQuery) async throws -> [SearchHit] { [] }
    func openInEditor(path: String, app: String) async throws {}
    func openPDF(slug: String) async throws {}
    func openTranslation(slug: String) async throws {}
    func hasTranslation(slug: String) -> Bool { false }
    func imageOriginalURL(forImageEntryPath path: String) async throws -> URL? { nil }
    func fileURL(for path: String) -> URL? { nil }
    func createImageObject(from sourceURL: URL, title: String?) async throws -> Entry {
        Entry(path: "", type: .image, title: "", author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }
    func createNote(path: String, text: String) async throws {}
    func moveToTrash(path: String) async throws -> String { "" }
    func listTrash() async throws -> [TrashItem] { [] }
    func restoreTrash(name: String) async throws -> String { "" }
    func purgeTrash(name: String) async throws {}
}
