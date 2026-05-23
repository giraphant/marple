import Testing
@testable import MarpleKit

@Suite struct MarkdownModelTests {
    @Test func testHeadingAndParagraph() {
        let blocks = MarkdownModel.blocks(from: "# Title\n\nA paragraph.")
        #expect(blocks == [
            .heading(level: 1, [.text("Title")]),
            .paragraph([.text("A paragraph.")]),
        ])
    }

    @Test func testParagraphKeepsWikilink() {
        let blocks = MarkdownModel.blocks(from: "See [[Foo]] here.")
        #expect(blocks == [
            .paragraph([.text("See "), .wikilink(target: "Foo", label: "Foo"), .text(" here.")]),
        ])
    }

    @Test func testBulletList() {
        let blocks = MarkdownModel.blocks(from: "- one\n- two")
        #expect(blocks == [
            .bulletList([[.text("one")], [.text("two")]]),
        ])
    }

    @Test func testCodeBlock() {
        let blocks = MarkdownModel.blocks(from: "```swift\nlet x = 1\n```")
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1\n")])
    }
}
