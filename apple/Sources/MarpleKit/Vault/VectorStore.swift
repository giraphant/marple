import Foundation
import Accelerate

/// In-memory dense-vector index for semantic search: an N×dim row-major matrix of
/// **unit-normalized** embeddings plus their paths. Query is brute-force cosine
/// (== dot, since rows and query are unit-norm) via a single BLAS matrix-vector
/// multiply — trivially fast at marple's scale (~15k × 1024). The MLX/embedding
/// side lives in MarpleEmbeddings; this stays pure so it's testable in core.
public struct VectorStore: Sendable {
    public let dim: Int
    public let paths: [String]
    let matrix: [Float]   // row-major, paths.count * dim, each row L2-normalized

    public init(dim: Int, paths: [String], matrix: [Float]) {
        precondition(matrix.count == paths.count * dim, "matrix shape mismatch")
        self.dim = dim
        self.paths = paths
        self.matrix = matrix
    }

    public var count: Int { paths.count }

    /// The unit vector for row `i` (used by the indexer to reuse unchanged rows).
    public func row(_ i: Int) -> [Float] {
        Array(matrix[(i * dim) ..< ((i + 1) * dim)])
    }

    /// Top-`k` by cosine, descending. `query` must be unit-norm and length `dim`.
    public func topK(_ query: [Float], k: Int) -> [(path: String, score: Float)] {
        let n = paths.count
        guard dim > 0, n > 0, k > 0, query.count == dim else { return [] }
        var scores = [Float](repeating: 0, count: n)
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                // scores[n] = M[n×dim] · q[dim]
                cblas_sgemv(
                    CblasRowMajor, CblasNoTrans, Int32(n), Int32(dim),
                    1, m.baseAddress, Int32(dim), q.baseAddress, 1,
                    0, &scores, 1)
            }
        }
        let top = Array(0..<n).sorted { scores[$0] > scores[$1] }.prefix(k)
        return top.map { (paths[$0], scores[$0]) }
    }
}

/// On-disk format for a `VectorStore`: a raw little-endian Float32 matrix
/// (`vectors.f32`) beside a JSON manifest (`vectors.json`) holding model id, dim,
/// and per-row path + content hash (the hash drives incremental re-embedding).
public enum VectorIndexIO {
    public struct Manifest: Codable, Sendable {
        public struct Row: Codable, Sendable {
            public let path: String
            public let hash: String
            public init(path: String, hash: String) { self.path = path; self.hash = hash }
        }
        public let model: String
        public let dim: Int
        public let rows: [Row]
        public init(model: String, dim: Int, rows: [Row]) {
            self.model = model; self.dim = dim; self.rows = rows
        }
    }

    public static func matrixURL(dir: URL) -> URL { dir.appendingPathComponent("vectors.f32") }
    public static func manifestURL(dir: URL) -> URL { dir.appendingPathComponent("vectors.json") }

    /// Atomic write of matrix + manifest into `dir`.
    public static func write(dir: URL, model: String, dim: Int,
                             rows: [(path: String, hash: String, vector: [Float])]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bytes = [Float](); bytes.reserveCapacity(rows.count * dim)
        for r in rows {
            precondition(r.vector.count == dim, "vector dim mismatch for \(r.path)")
            bytes.append(contentsOf: r.vector)
        }
        try bytes.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: matrixURL(dir: dir), options: .atomic)
        let manifest = Manifest(model: model, dim: dim,
                                rows: rows.map { .init(path: $0.path, hash: $0.hash) })
        try JSONEncoder().encode(manifest).write(to: manifestURL(dir: dir), options: .atomic)
    }

    /// Load matrix + manifest from `dir`, or nil if absent. Returns the queryable
    /// store plus the manifest (whose hashes the indexer needs for incremental builds).
    public static func read(dir: URL) throws -> (store: VectorStore, manifest: Manifest)? {
        let mURL = manifestURL(dir: dir), fURL = matrixURL(dir: dir)
        guard FileManager.default.fileExists(atPath: mURL.path),
              FileManager.default.fileExists(atPath: fURL.path) else { return nil }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: mURL))
        guard manifest.dim > 0 else { return nil }
        let data = try Data(contentsOf: fURL)
        let (floats, floatOverflow) = manifest.rows.count.multipliedReportingOverflow(by: manifest.dim)
        guard !floatOverflow else { return nil }
        let (expected, byteOverflow) = floats.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !byteOverflow, data.count == expected else { return nil }  // stale/corrupt → rebuild
        let matrix = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let store = VectorStore(dim: manifest.dim,
                                paths: manifest.rows.map(\.path), matrix: matrix)
        return (store, manifest)
    }
}
