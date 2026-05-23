import Testing
@testable import MarpleKit

@Suite struct WikilinkTests {
    @Test func testPlainTextIsOneTextToken() {
        #expect(Wikilink.tokenize("just text") == [.text("just text")])
    }
    @Test func testSingleWikilink() {
        #expect(Wikilink.tokenize("see [[Foo]] now") ==
                [.text("see "), .wikilink(target: "Foo", label: "Foo"), .text(" now")])
    }
    @Test func testPipedLabel() {
        #expect(Wikilink.tokenize("[[foo/bar.md|Bar]]") ==
                [.wikilink(target: "foo/bar.md", label: "Bar")])
    }
    @Test func testProtectRestoreRoundTrip() {
        let (protected, refs) = Wikilink.protect("a [[X]] b")
        #expect(!protected.contains("[["))
        #expect(Wikilink.restore(protected, refs) ==
                [.text("a "), .wikilink(target: "X", label: "X"), .text(" b")])
    }
}
