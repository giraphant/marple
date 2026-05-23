import Testing
import Foundation
@testable import MarpleKit

@Suite struct TextEmbedderTests {
    @Test func testStubShapeAndDeterminism() async throws {
        let e: TextEmbedder = StubTextEmbedder(dimension: 16)
        let out = try await e.embed(["机器学习", "深度学习"])
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.count == 16 })
        let again = try await e.embed(["机器学习"])
        #expect(again[0] == out[0])
    }

    @Test func testStubVectorsAreL2Normalized() async throws {
        let e = StubTextEmbedder(dimension: 32)
        let v = try await e.embed("语义检索")
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(norm - 1) < 1e-5)
    }

    @Test func testSingleConvenienceMatchesBatch() async throws {
        let e = StubTextEmbedder(dimension: 8)
        let single = try await e.embed("向量")
        let batch = try await e.embed(["向量"])
        #expect(single == batch[0])
    }
}
