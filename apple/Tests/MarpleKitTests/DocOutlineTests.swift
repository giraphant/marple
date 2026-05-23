import Testing
@testable import MarpleKit

@Suite struct DocOutlineTests {
    @Test func extractsHeadingsWithLevelsAndIndex() {
        let blocks = MarkdownModel.blocks(from: "# A\n\npara\n\n## B\n\n### C")
        let items = outline(from: blocks)
        #expect(items.map(\.level) == [1, 2, 3])
        #expect(items.map(\.text) == ["A", "B", "C"])
        for it in items {
            guard case .heading = blocks[it.blockIndex] else {
                Issue.record("blockIndex \(it.blockIndex) is not a heading"); continue
            }
        }
    }
    @Test func ignoresNonHeadingBlocks() {
        let blocks = MarkdownModel.blocks(from: "para only\n\n- a\n- b")
        #expect(outline(from: blocks).isEmpty)
    }
    @Test func headingInCodeBlockNotCounted() {
        let blocks = MarkdownModel.blocks(from: "```\n# not a heading\n```")
        #expect(outline(from: blocks).isEmpty)
    }
    @Test func wikilinkHeadingUsesLabelText() {
        let blocks = MarkdownModel.blocks(from: "# [[target|Shown]]")
        #expect(outline(from: blocks).map(\.text) == ["Shown"])
    }
}
