import Foundation

/// The seam that hides "how text becomes a vector" from the rest of the app —
/// same idea as `VaultClient`: callers depend on this protocol, the concrete
/// model/runtime (MLX, ONNX, …) is a swappable impl. Lets us prototype the
/// pipeline on a small model now and drop in Qwen3-Embedding-8B later without
/// touching call sites.
public protocol TextEmbedder: Sendable {
    /// Output vector length. Constant for a given model.
    var dimension: Int { get }
    /// Map each input text to a fixed-length dense vector, order-preserving.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public extension TextEmbedder {
    func embed(_ text: String) async throws -> [Float] {
        try await embed([text]).first ?? []
    }
}

/// Deterministic fake for tests and pipeline plumbing — no model, no I/O.
/// Hashes characters into `dimension` buckets and L2-normalizes, so the same
/// text always yields the same unit vector and cosine stays meaningful.
public struct StubTextEmbedder: TextEmbedder {
    public let dimension: Int
    public init(dimension: Int = 8) { self.dimension = dimension }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { Self.vector(for: $0, dimension: dimension) }
    }

    static func vector(for text: String, dimension: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for scalar in text.unicodeScalars {
            v[Int(scalar.value % UInt32(dimension))] += 1
        }
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
