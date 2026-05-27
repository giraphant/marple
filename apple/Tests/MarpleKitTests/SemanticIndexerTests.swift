import Testing
import Foundation
@testable import MarpleKit

@Suite struct SemanticIndexerTests {
    private func tmpDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("semidx-\(UUID().uuidString)")
    }

    @Test func testFirstBuildEmbedsAll() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let idx = SemanticIndexer(embedder: StubTextEmbedder(dimension: 8))
        let docs = [SemanticDoc(path: "a.md", text: "机器学习"),
                    SemanticDoc(path: "b.md", text: "深度学习"),
                    SemanticDoc(path: "c.md", text: "强化学习")]
        let r = try await idx.build(dir: dir, model: "stub", docs: docs)
        #expect(r == SemanticBuildResult(embedded: 3, reused: 0, total: 3))

        let loaded = try #require(try VectorIndexIO.read(dir: dir))
        #expect(loaded.manifest.rows.map(\.path) == ["a.md", "b.md", "c.md"])
        #expect(loaded.store.dim == 8)
    }

    @Test func testRebuildReusesUnchanged() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let idx = SemanticIndexer(embedder: StubTextEmbedder(dimension: 8))
        let docs = [SemanticDoc(path: "a.md", text: "机器学习"),
                    SemanticDoc(path: "b.md", text: "深度学习")]
        _ = try await idx.build(dir: dir, model: "stub", docs: docs)

        // identical second build → nothing re-embedded
        let same = try await idx.build(dir: dir, model: "stub", docs: docs)
        #expect(same == SemanticBuildResult(embedded: 0, reused: 2, total: 2))

        // change one doc → only it re-embeds
        let changed = [SemanticDoc(path: "a.md", text: "机器学习"),
                       SemanticDoc(path: "b.md", text: "深度学习与神经网络")]
        let r = try await idx.build(dir: dir, model: "stub", docs: changed)
        #expect(r == SemanticBuildResult(embedded: 1, reused: 1, total: 2))
    }

    @Test func testModelChangeForcesFullReembed() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let idx = SemanticIndexer(embedder: StubTextEmbedder(dimension: 8))
        let docs = [SemanticDoc(path: "a.md", text: "x")]
        _ = try await idx.build(dir: dir, model: "model-v1", docs: docs)
        let r = try await idx.build(dir: dir, model: "model-v2", docs: docs)
        #expect(r.embedded == 1 && r.reused == 0)   // different model ⇒ ignore old vectors
    }

    @Test func testSearcherReturnsRankedSubset() async throws {
        let stub = StubTextEmbedder(dimension: 16)
        let docs = [SemanticDoc(path: "a.md", text: "机器学习与统计"),
                    SemanticDoc(path: "b.md", text: "晚饭吃什么"),
                    SemanticDoc(path: "c.md", text: "强化学习算法")]
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await SemanticIndexer(embedder: stub).build(dir: dir, model: "stub", docs: docs)
        let store = try #require(try VectorIndexIO.read(dir: dir)).store

        let hits = try await SemanticSearcher(embedder: stub, store: store)
            .search("机器学习", topK: 2)
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { ["a.md", "b.md", "c.md"].contains($0.path) })
        #expect(hits[0].score >= hits[1].score)   // descending
    }

    @Test func testSearcherFiltersLowConfidenceNearestNeighbors() async throws {
        let query = [Float(1), 0]
        let weakY = (1 - Float(0.47 * 0.47)).squareRoot()
        let noiseY = (1 - Float(0.20 * 0.20)).squareRoot()
        let store = VectorStore(
            dim: 2,
            paths: ["confident.md", "weak.md", "noise.md"],
            matrix: [0.50, Float(0.75).squareRoot(), 0.47, weakY, 0.20, noiseY]
        )

        let hits = try await SemanticSearcher(embedder: FixedTextEmbedder(vector: query), store: store)
            .search("meaningless", topK: 3)

        #expect(hits.map(\.path) == ["confident.md"])
    }
}

private struct FixedTextEmbedder: TextEmbedder {
    let vector: [Float]
    var dimension: Int { vector.count }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in vector }
    }
}
