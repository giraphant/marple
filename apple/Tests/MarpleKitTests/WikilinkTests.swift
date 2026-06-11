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
    // QUA-225 issue 2: stem-form wikilinks render to a marple://wiki link exactly
    // like piped/path forms — preprocessing is unconditional and form-agnostic, so
    // a "no link rendered" report can't originate in this stage.
    @Test func testStemFormPreprocessesToWikiLink() {
        #expect(Wikilink.preprocessForRendering("[[donna-haraway|Donna Haraway]]")
                == "[Donna Haraway](marple://wiki/donna-haraway)")
    }
    @Test func testPathFormPreprocessesToWikiLink() {
        #expect(Wikilink.preprocessForRendering("[[papers/x|label]]")
                == "[label](marple://wiki/papers/x)")
    }
    @Test func testProtectRestoreRoundTrip() {
        let (protected, refs) = Wikilink.protect("a [[X]] b")
        #expect(!protected.contains("[["))
        #expect(Wikilink.restore(protected, refs) ==
                [.text("a "), .wikilink(target: "X", label: "X"), .text(" b")])
    }
}
