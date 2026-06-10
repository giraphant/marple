import Foundation
import MarpleKit

extension AppModel {
    func cliSearch(query: String, limit: Int) async throws -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // Self-heal the watcher race: an agent may search for a file it wrote
        // moments ago, before the 0.4s-debounced FSEvents reconcile landed it in
        // the index. Reconcile synchronously first. CLI-only path — the in-app
        // search box never calls this, so the live UI keeps its cached speed.
        await cliRefreshIndex()
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
        guard await cliEnsureIndexed(path: path) else {
            throw CLIBackendError.notFound(path)
        }
        if let existing = tabs.first(where: { $0.location.openPath == path }) {
            await selectTab(existing.id)
        } else {
            await openInNewTab(path)
        }
    }

    /// Ensure `path` is present in the live index, self-healing the FSEvents
    /// watcher race. Already indexed → true immediately. Missing but the file
    /// exists on disk under the workspace → run a synchronous reconcile and
    /// re-check. A path that's missing from disk too stays false without paying
    /// for a reconcile (a genuine not-found, not the write-then-access race).
    func cliEnsureIndexed(path: String) async -> Bool {
        if entries.contains(where: { $0.path == path }) { return true }
        guard FileManager.default.fileExists(atPath: workspaceRoot + "/" + path) else {
            return false
        }
        await cliRefreshIndex()
        return entries.contains(where: { $0.path == path })
    }

    /// Run the same reconcile + index reload the FSEvents watcher does, on
    /// demand, through the shared single-flight `refreshGate` (QUA-212): a
    /// watcher/boot chain already mid-run is joined — request a trailing rerun
    /// and wait for that fresh pass — instead of stacking a duplicate full
    /// vault walk behind the indexer writeLock. No-op when no indexer is wired
    /// (stub-backed tests).
    func cliRefreshIndex() async {
        guard cliIndexer != nil else { return }
        if await refreshGate.beginOrJoin() {
            repeat { await refreshChain() } while await refreshGate.finishOrRerun()
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
