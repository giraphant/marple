import Testing
@testable import MarpleKit

@Suite struct ResolveTests {
    let entries = [
        Entry(path: "vault/papers/foo.md", type: .paper, title: "Foo Paper",
              author: [], year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false),
        Entry(path: "vault/notes/bar.md", type: .note, title: "Bar",
              author: [], year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false),
    ]

    @Test func testResolveByTitle() {
        #expect(WikiResolver.resolve("Foo Paper", in: entries)?.path == "vault/papers/foo.md")
    }

    @Test func testResolveByPathStem() {
        #expect(WikiResolver.resolve("bar", in: entries)?.path == "vault/notes/bar.md")
    }

    @Test func testUnresolvedIsNil() {
        #expect(WikiResolver.resolve("nothing", in: entries) == nil)
    }
}
