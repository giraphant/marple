import Testing
import Foundation
@testable import MarpleKit

@Suite struct VectorStoreTests {
    private static let s2 = Float(1) / Float(2).squareRoot()  // 1/√2

    private func sample() -> VectorStore {
        // 3 unit vectors in 2-D: A=[1,0] B=[0,1] C=[1,1]/√2
        VectorStore(dim: 2, paths: ["A", "B", "C"],
                    matrix: [1, 0,  0, 1,  Self.s2, Self.s2])
    }

    @Test func testTopKOrdersByCosine() {
        let hits = sample().topK([1, 0], k: 2)
        #expect(hits.map(\.path) == ["A", "C"])
        #expect(abs(hits[0].score - 1) < 1e-6)
        #expect(abs(hits[1].score - Self.s2) < 1e-6)
    }

    @Test func testTopKClampsAndGuards() {
        let store = sample()
        #expect(store.topK([1, 0], k: 99).count == 3)        // k > n
        #expect(store.topK([1, 0, 0], k: 2).isEmpty)          // wrong dim
        #expect(store.topK([1, 0], k: 0).isEmpty)
    }

    @Test func testDiskRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vecstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let rows: [(path: String, hash: String, vector: [Float])] = [
            ("A", "h1", [1, 0]), ("B", "h2", [0, 1]), ("C", "h3", [Self.s2, Self.s2]),
        ]
        try VectorIndexIO.write(dir: dir, model: "test-model", dim: 2, rows: rows)

        let loaded = try #require(try VectorIndexIO.read(dir: dir))
        #expect(loaded.manifest.model == "test-model")
        #expect(loaded.manifest.dim == 2)
        #expect(loaded.manifest.rows.map(\.hash) == ["h1", "h2", "h3"])
        #expect(loaded.store.paths == ["A", "B", "C"])
        #expect(loaded.store.topK([0, 1], k: 1).first?.path == "B")
    }

    @Test func testReadMissingReturnsNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vecstore-missing-\(UUID().uuidString)")
        #expect(try VectorIndexIO.read(dir: dir) == nil)
    }
}
