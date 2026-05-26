import Foundation
import MarpleKit

extension AppModel {
    func cliSearch(query: String, limit: Int) async throws -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let hits = try await client.search(SearchQuery(q: q, type: nil, limit: max(1, limit)))
        return hits.map(\.entry)
    }

    func cliEntry(path: String) -> Entry? {
        entries.first { $0.path == path }
    }

    func cliReadEntry(path: String) async throws -> (frontmatter: String, body: String) {
        let raw = try await client.entryText(path: path)
        let split = Frontmatter.split(raw)
        return (split.frontmatter ?? "", split.body)
    }

    func cliOpenDocument(path: String) async throws {
        guard entries.contains(where: { $0.path == path }) else {
            throw CLIBackendError.notFound(path)
        }
        if let existing = tabs.first(where: { $0.location.openPath == path }) {
            await selectTab(existing.id)
        } else {
            await openInNewTab(path)
        }
    }
}

/// Errors the CLI extension surfaces directly to the dispatcher.
enum CLIBackendError: Error, CustomStringConvertible {
    case notFound(String)

    var description: String {
        switch self {
        case .notFound(let path): return "entry not found in index: \(path)"
        }
    }
}
