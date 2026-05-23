import Testing
@testable import MarpleKit

@Suite struct VaultClientStubTests {
    @Test func testStubReturnsSeededEntries() async throws {
        let e = Entry(path: "vault/p/a.md", type: .paperAnalysis, title: "A",
                      author: nil, year: nil, ratingScore: 0, themes: [],
                      preview: "", hasPDF: false)
        let client: VaultClient = StubVaultClient(entries: [e], texts: ["vault/p/a.md": "# A"])
        let idx = try await client.index()
        #expect(idx == [e])
        let body = try await client.entryText(path: "vault/p/a.md")
        #expect(body == "# A")
    }

    @Test func testStubMissingTextThrowsNotFound() async {
        let client: VaultClient = StubVaultClient(entries: [], texts: [:])
        do {
            _ = try await client.entryText(path: "nope.md")
            Issue.record("expected throw")
        } catch let err as VaultError {
            #expect(err == .notFound("nope.md"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}
