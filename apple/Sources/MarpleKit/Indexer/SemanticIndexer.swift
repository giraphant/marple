import Foundation
import CryptoKit

public struct SemanticDoc: Sendable {
    public let path: String
    public let text: String
    public init(path: String, text: String) { self.path = path; self.text = text }
}

public struct SemanticBuildResult: Sendable, Equatable {
    public let embedded: Int
    public let reused: Int
    public let total: Int
}

/// Builds/updates the on-disk vector index from documents, embedding only those
/// whose text changed since the last build (content-hash diff) and reusing the
/// rest. Depends only on the `TextEmbedder` seam + `VectorStore`, so it's fully
/// testable with `StubTextEmbedder` — the MLX runtime is not required here.
public struct SemanticIndexer: Sendable {
    let embedder: any TextEmbedder
    public init(embedder: any TextEmbedder) { self.embedder = embedder }

    public func build(
        dir: URL, model: String, docs: [SemanticDoc], batchSize: Int = 64,
        checkpointEvery: Int = 2000,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> SemanticBuildResult {
        let dim = embedder.dimension
        var prevByPath: [String: (hash: String, vec: [Float])] = [:]
        if let prev = try VectorIndexIO.read(dir: dir),
           prev.manifest.dim == dim, prev.manifest.model == model {
            for (i, r) in prev.manifest.rows.enumerated() {
                prevByPath[r.path] = (r.hash, prev.store.row(i))
            }
        }

        var rows: [(path: String, hash: String, vector: [Float])] = []
        rows.reserveCapacity(docs.count)
        var toEmbed: [(row: Int, text: String)] = []
        var reused = 0
        for doc in docs {
            let h = Self.hash(doc.text)
            if let prev = prevByPath[doc.path], prev.hash == h {
                rows.append((doc.path, h, prev.vec)); reused += 1
            } else {
                rows.append((doc.path, h, []))
                toEmbed.append((rows.count - 1, doc.text))
            }
        }

        var done = 0, i = 0, sinceCheckpoint = 0
        while i < toEmbed.count {
            let batch = Array(toEmbed[i ..< min(i + batchSize, toEmbed.count)])
            let vecs = try await embedder.embed(batch.map(\.text))
            for (b, v) in zip(batch, vecs) { rows[b.row].vector = v }
            done += batch.count; i += batchSize; sinceCheckpoint += batch.count
            progress?(done, toEmbed.count)
            // Checkpoint only the completed rows so an interrupted long build is
            // both usable and resumable (the next run reuses these by hash).
            if checkpointEvery > 0, sinceCheckpoint >= checkpointEvery, i < toEmbed.count {
                try VectorIndexIO.write(dir: dir, model: model, dim: dim,
                               rows: rows.filter { $0.vector.count == dim })
                sinceCheckpoint = 0
            }
        }

        try VectorIndexIO.write(dir: dir, model: model, dim: dim, rows: rows)
        return SemanticBuildResult(embedded: toEmbed.count, reused: reused, total: docs.count)
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
}
