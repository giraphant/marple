import AppKit
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

    @Test func renderedTablesUseTextTableBlocks() throws {
        let rendered = Self.renderTable("| A | B |\n|---|---|\n| 1 | 22 |")
        let headerBlock = try Self.tableBlock(in: rendered, containing: "A")
        let bodyBlock = try Self.tableBlock(in: rendered, containing: "22")

        #expect(headerBlock.startingRow == 0)
        #expect(headerBlock.startingColumn == 0)
        #expect(bodyBlock.startingRow == 1)
        #expect(bodyBlock.startingColumn == 1)
        #expect(headerBlock.table.numberOfColumns == 2)
        #expect(bodyBlock.table === headerBlock.table)
        #expect(!rendered.attributedString.string.contains(" | "))
    }

    @Test func renderedTablesUseReaderTableStyling() throws {
        let rendered = Self.renderTable("| A | B |\n|---|---|\n| 1 | |")
        let headerBlock = try Self.tableBlock(in: rendered, containing: "A")
        let emptyCellBlock = try Self.tableBlock(in: rendered, containing: "—")

        #expect(headerBlock.width(for: .padding, edge: .minX) == 10)
        #expect(headerBlock.width(for: .padding, edge: .maxX) == 10)
        #expect(headerBlock.width(for: .padding, edge: .minY) == 6)
        #expect(headerBlock.width(for: .padding, edge: .maxY) == 6)
        #expect(emptyCellBlock.width(for: .border, edge: .minX) == 0)
        #expect(emptyCellBlock.width(for: .border, edge: .maxX) == 0)
        #expect(emptyCellBlock.width(for: .border, edge: .maxY) == 0.5)
        #expect(headerBlock.backgroundColor != nil)
        #expect(try Self.foregroundColor(in: rendered, containing: "—") == .tertiaryLabelColor)
    }

    @Test func renderedTablesUseCompactAdaptiveColumns() throws {
        let markdown = """
        | 概念 | 首次提出 | 演化 | 来源作品 |
        |---|---|---|---|
        | 转导 | 2002 | 从 Simondon 的个体化哲学核心概念，到分析技术-身体耦合的基本工具，再到后续著作中持续回响的本体论底色 | Transductions 全书 |
        """
        let rendered = Self.renderTable(markdown)
        let proseStyle = try Self.paragraphStyle(in: rendered, containing: "Simondon")
        let yearBlock = try Self.tableBlock(in: rendered, containing: "2002")
        let proseBlock = try Self.tableBlock(in: rendered, containing: "Simondon")

        #expect(yearBlock.table.layoutAlgorithm == .fixedLayoutAlgorithm)
        #expect(yearBlock.valueType(for: .width) == .percentageValueType)
        #expect(proseBlock.valueType(for: .width) == .percentageValueType)
        #expect(proseBlock.value(for: .width) > yearBlock.value(for: .width) * 2)
        #expect(proseStyle.lineSpacing < Self.tableRenderStyle.lineSpacing)
    }

    private static var tableRenderStyle: RenderStyle {
        RenderStyle(size: 17, design: .sans, lineHeight: 1.6)
    }

    private static func renderTable(_ markdown: String) -> RenderedDocument {
        MarkdownRenderer.render(markdown, style: tableRenderStyle)
    }

    private static func tableBlock(in rendered: RenderedDocument, containing text: String) throws -> NSTextTableBlock {
        let style = try paragraphStyle(in: rendered, containing: text)
        return try #require(style.textBlocks.first as? NSTextTableBlock)
    }

    private static func paragraphStyle(in rendered: RenderedDocument, containing text: String) throws -> NSParagraphStyle {
        let range = try range(of: text, in: rendered)
        let attribute = rendered.attributedString.attribute(.paragraphStyle,
                                                            at: range.location,
                                                            effectiveRange: nil)
        return try #require(attribute as? NSParagraphStyle)
    }

    private static func foregroundColor(in rendered: RenderedDocument, containing text: String) throws -> NSColor {
        let range = try range(of: text, in: rendered)
        let attribute = rendered.attributedString.attribute(.foregroundColor,
                                                            at: range.location,
                                                            effectiveRange: nil)
        return try #require(attribute as? NSColor)
    }

    private static func range(of text: String, in rendered: RenderedDocument) throws -> NSRange {
        let range = (rendered.attributedString.string as NSString).range(of: text)
        try #require(range.location != NSNotFound)
        return range
    }
}
