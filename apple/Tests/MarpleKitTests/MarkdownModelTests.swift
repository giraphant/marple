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

    @Test func testStripsLeadingKVLabelBlock() {
        let body = """
        # 标题

        **英文原标题**：The Title
        **作者**：Someone

        ## 正文

        Real content.
        """
        #expect(MarkdownModel.blocks(from: body) == [
            .heading(level: 1, [.text("标题")]),
            .heading(level: 2, [.text("正文")]),
            .paragraph([.text("Real content.")]),
        ])
    }

    @Test func testKeepsKVShapedLineAfterContent() {
        let body = "Intro prose.\n\n**Note**：kept because it follows real content."
        #expect(MarkdownModel.blocks(from: body) == [
            .paragraph([.text("Intro prose.")]),
            .paragraph([.text("Note：kept because it follows real content.")]),
        ])
    }
}
