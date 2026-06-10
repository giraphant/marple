import Foundation
import MarpleKit

/// Read-only `VaultClient` for iOS. Reads entries/search from the on-device
/// `IndexDatabase` (built into the app container) and entry text from the
/// synced vault files (materializing them from iCloud first). Write/open
/// operations are unsupported in v1.
struct IOSVaultClient: VaultClient {
    let workspaceRoot: String
    let db: IndexDatabase   // named `db`, not `index`, to avoid colliding with index()

    func index() async throws -> [Entry] { try db.loadEntries() }

    func search(_ query: SearchQuery) async throws -> [SearchHit] {
        try db.search(query.q, type: query.type, minRating: query.minRating,
                      theme: query.theme, limit: query.limit)
    }

    func entryText(path: String) async throws -> String {
        let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(path)
        try await ICloudMaterializer.ensureDownloaded(url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func fileURL(for path: String) -> URL? {
        URL(fileURLWithPath: workspaceRoot).appendingPathComponent(path)
    }

    // MARK: Unsupported in the read-only companion (UI never calls these in v1).
    func openInEditor(path: String, app: String) async throws {}
    func openPDF(slug: String) async throws { throw VaultError.notFound("read-only") }
    func openTranslation(slug: String) async throws { throw VaultError.notFound("read-only") }
    func hasTranslation(slug: String) -> Bool { false }
    func imageOriginalURL(forImageEntryPath path: String) async throws -> URL? { nil }
    func createImageObject(from sourceURL: URL, title: String?) async throws -> Entry {
        throw VaultError.notFound("read-only")
    }
    func writeFile(path: String, text: String) async throws { throw VaultError.notFound("read-only") }
    func createNote(path: String, text: String) async throws { throw VaultError.notFound("read-only") }
    func moveToTrash(path: String) async throws -> String { throw VaultError.notFound("read-only") }
    func listTrash() async throws -> [TrashItem] { [] }
    func restoreTrash(name: String) async throws -> String { throw VaultError.notFound("read-only") }
    func purgeTrash(name: String) async throws { throw VaultError.notFound("read-only") }
}
