import Foundation
import MarpleKit

@MainActor
enum CLIHandlers {
    static func handle(_ req: CLIRequest, model: AppModel, indexer: VaultIndexer) async -> CLIResponse {
        do {
            switch req.method {
            case CLIMethod.ping:
                return .success(CLIResponseData(pong: "marple"))
            case CLIMethod.search:
                return try await search(req: req, model: model)
            case CLIMethod.read:
                return try await read(req: req, model: model)
            case CLIMethod.open:
                return try await open(req: req, model: model)
            default:
                return .failure(code: CLIErrorCode.badRequest, message: "unknown method: \(req.method)")
            }
        } catch let e as CLIBackendError {
            switch e {
            case .notFound(let p):
                return .failure(code: CLIErrorCode.notFound, message: "entry not in index: \(p)")
            }
        } catch {
            return .failure(code: CLIErrorCode.internalError, message: "\(error)")
        }
    }

    private static func search(req: CLIRequest, model: AppModel) async throws -> CLIResponse {
        guard let q = req.query, !q.isEmpty else {
            return .failure(code: CLIErrorCode.badRequest, message: "missing query")
        }
        let hits = try await model.cliSearch(query: q, limit: req.limit ?? 20)
        return .success(CLIResponseData(entries: hits.map(toDigest)))
    }

    private static func read(req: CLIRequest, model: AppModel) async throws -> CLIResponse {
        guard let path = req.path else {
            return .failure(code: CLIErrorCode.badRequest, message: "missing path")
        }
        guard await model.cliEnsureIndexed(path: path),
              let entry = model.cliEntry(path: path) else {
            return .failure(code: CLIErrorCode.notFound, message: "not found: \(path)")
        }
        let (fm, body) = try await model.cliReadEntry(path: path)
        return .success(CLIResponseData(entry: EntryDetail(
            digest: toDigest(entry), frontmatter: fm, body: body
        )))
    }

    private static func open(req: CLIRequest, model: AppModel) async throws -> CLIResponse {
        guard let path = req.path else {
            return .failure(code: CLIErrorCode.badRequest, message: "missing path")
        }
        try await model.cliOpenDocument(path: path)
        return .success(CLIResponseData(opened: true))
    }

    private static func toDigest(_ entry: Entry) -> EntryDigest {
        EntryDigest(
            path: entry.path,
            title: entry.title,
            type: entry.type.rawValue,
            themes: entry.themes,
            author: entry.author,
            year: entry.year,
            mtime: entry.mtime
        )
    }
}
