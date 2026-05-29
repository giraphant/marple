import AppKit
import Testing
@testable import Marple
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

    @Test func renderedTablesUseEnclosedHairlineGridStyling() throws {
        let rendered = Self.renderTable("| A | B |\n|---|---|\n| 1 | |")
        let headerBlock = try Self.tableBlock(in: rendered, containing: "A")
        let emptyCellBlock = try Self.tableBlock(in: rendered, containing: "—")
        let headerFont = try Self.font(in: rendered, containing: "A")
        let bodyFont = try Self.font(in: rendered, containing: "1")

        #expect(headerBlock.width(for: .padding, edge: .minX) == 12)
        #expect(headerBlock.width(for: .padding, edge: .maxX) == 12)
        #expect(headerBlock.width(for: .padding, edge: .minY) == 7)
        #expect(headerBlock.width(for: .padding, edge: .maxY) == 7)
        // Outer frame on the leading column + top, stronger rule under the header.
        #expect(headerBlock.width(for: .border, edge: .minX) == 0.75)
        #expect(headerBlock.width(for: .border, edge: .minY) == 0.75)
        #expect(headerBlock.width(for: .border, edge: .maxY) == 0.75)
        // Trailing column carries the right-hand outer frame; inner edge is a hairline.
        #expect(emptyCellBlock.width(for: .border, edge: .minX) == 0.5)
        #expect(emptyCellBlock.width(for: .border, edge: .maxX) == 0.75)
        #expect(emptyCellBlock.width(for: .border, edge: .maxY) == 0.75)
        let headerBackground = try #require(headerBlock.backgroundColor)
        #expect(Self.alpha(of: headerBackground) == 0.04)
        #expect(headerFont.pointSize == 15.3)
        #expect(bodyFont.pointSize == 15.3)
        #expect(Self.fontWeight(headerFont) > Self.fontWeight(bodyFont))
        #expect(try Self.kern(in: rendered, containing: "A") > 0)
        #expect(try Self.foregroundColor(in: rendered, containing: "A") == .secondaryLabelColor)
        #expect(try Self.foregroundColor(in: rendered, containing: "—") == .tertiaryLabelColor)
    }

    @Test func renderedTablesEncloseColumnsWithoutZebra() throws {
        let rendered = Self.renderTable("| Term | Value |\n|---|---|\n| Alpha | 1 |\n| Beta | 2 |")
        let firstColumnInnerRow = try Self.tableBlock(in: rendered, containing: "Alpha")
        let secondColumnInnerRow = try Self.tableBlock(in: rendered, containing: "1")
        let firstColumnLastRow = try Self.tableBlock(in: rendered, containing: "Beta")

        // Body rows carry no fill — the design never stripes.
        #expect(secondColumnInnerRow.backgroundColor == nil)
        #expect(firstColumnLastRow.backgroundColor == nil)
        // Leading column framed; inner column separated by a faint vertical hairline.
        #expect(firstColumnInnerRow.width(for: .border, edge: .minX) == 0.75)
        #expect(secondColumnInnerRow.width(for: .border, edge: .minX) == 0.5)
        #expect(secondColumnInnerRow.width(for: .border, edge: .maxX) == 0.75)
        // Faint horizontal hairline between body rows (not the heavier outer frame).
        #expect(firstColumnInnerRow.width(for: .border, edge: .maxY) == 0.5)
    }

    @Test func renderedTablesHonorColumnAlignmentMarkers() throws {
        let rendered = Self.renderTable("| Left | Number | Scope |\n|:---|---:|:---:|\n| Alpha | 42 | middle |")
        let leftStyle = try Self.paragraphStyle(in: rendered, containing: "Alpha")
        let numberStyle = try Self.paragraphStyle(in: rendered, containing: "42")
        let scopeStyle = try Self.paragraphStyle(in: rendered, containing: "middle")

        #expect(leftStyle.alignment == .left)
        #expect(numberStyle.alignment == .right)
        #expect(scopeStyle.alignment == .center)
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

    @Test func renderedBodyUsesUlyssesProseRhythm() throws {
        let rendered = Self.renderUlyssesReference("A paragraph.")
        let font = try Self.font(in: rendered, containing: "A paragraph")
        let paragraphStyle = try Self.paragraphStyle(in: rendered, containing: "A paragraph")

        #expect(font.pointSize == 15)
        #expect(paragraphStyle.lineSpacing == 9.3)
        #expect(paragraphStyle.paragraphSpacing == 14.25)
    }

    @Test func renderedHeadingsUseReaderHierarchy() throws {
        let rendered = Self.renderUlyssesReference("# H1\n\n## H2\n\n### H3\n\n###### H6")
        let h1Font = try Self.font(in: rendered, containing: "H1")
        let h2Font = try Self.font(in: rendered, containing: "H2")
        let h3Font = try Self.font(in: rendered, containing: "H3")
        let h6Font = try Self.font(in: rendered, containing: "H6")
        let standaloneH2 = Self.renderUlyssesReference("## H2")
        let h2ParagraphStyle = try Self.paragraphStyle(in: standaloneH2, containing: "H2")

        #expect(h1Font.pointSize == 27)
        #expect(h2Font.pointSize == 22.5)
        #expect(h3Font.pointSize == 18.75)
        #expect(h6Font.pointSize == 15)
        #expect(h2ParagraphStyle.paragraphSpacingBefore == 0)
        #expect(h2ParagraphStyle.paragraphSpacing == 6)
    }

    @Test func adjacentHeadingsUseCompactClusterSpacing() throws {
        let rendered = Self.renderUlyssesReference("## 项目关联\n\n### BTS: Body, Technology and Society")
        let h2ParagraphStyle = try Self.paragraphStyle(in: rendered, containing: "项目关联")
        let h3ParagraphStyle = try Self.paragraphStyle(in: rendered, containing: "BTS")

        #expect(h2ParagraphStyle.paragraphSpacing == 6)
        #expect(h3ParagraphStyle.paragraphSpacingBefore == 0)
        #expect(h3ParagraphStyle.paragraphSpacing == 6)
    }

    @Test func headingsAfterBodyUseTightSectionSpacingIncrement() throws {
        let rendered = Self.renderUlyssesReference("Intro paragraph.\n\n## Section")
        let h2ParagraphStyle = try Self.paragraphStyle(in: rendered, containing: "Section")

        #expect(h2ParagraphStyle.paragraphSpacingBefore == 3.75)
        #expect(h2ParagraphStyle.paragraphSpacing == 6)
    }

    @Test func headingsUseGraduatedWeights() throws {
        let rendered = Self.renderUlyssesReference("# H1\n\n## H2\n\n### H3")
        let h1Font = try Self.font(in: rendered, containing: "H1")
        let h2Font = try Self.font(in: rendered, containing: "H2")
        let h3Font = try Self.font(in: rendered, containing: "H3")

        #expect(Self.fontWeight(h1Font) > Self.fontWeight(h2Font))
        #expect(Self.fontWeight(h2Font) > Self.fontWeight(h3Font))
    }

    @Test func renderedBlockQuoteUsesUlyssesReferenceIndentAndDimText() throws {
        let rendered = Self.renderUlyssesReference("> Quoted text")
        let paragraphStyle = try Self.paragraphStyle(in: rendered, containing: "Quoted")
        let color = try Self.foregroundColor(in: rendered, containing: "Quoted")

        #expect(paragraphStyle.headIndent == 28)
        #expect(paragraphStyle.firstLineHeadIndent == 28)
        #expect(paragraphStyle.paragraphSpacingBefore == 24)
        #expect(paragraphStyle.paragraphSpacing == 24)
        #expect(color == Self.ulyssesReferenceStyle.quoteTextColor)
    }

    @Test func renderedInlineCodeUsesUlyssesReferenceScaleAndBackground() throws {
        let rendered = Self.renderUlyssesReference("See `subject` field.")
        let font = try Self.font(in: rendered, containing: "subject")
        let backgroundColor = try Self.backgroundColor(in: rendered, containing: "subject")

        #expect(font.pointSize == 13.8)
        #expect(backgroundColor == Self.ulyssesReferenceStyle.codeBackgroundColor)
    }

    @Test func renderedThematicBreakUsesCenteredDots() throws {
        let rendered = Self.renderUlyssesReference("Before\n\n---\n\nAfter")
        let paragraphStyle = try Self.paragraphStyle(in: rendered, containing: "· · ·")
        let kern = try Self.kern(in: rendered, containing: "· · ·")

        #expect(rendered.attributedString.string.contains("· · ·"))
        #expect(paragraphStyle.alignment == .center)
        #expect(paragraphStyle.paragraphSpacingBefore == 14.25)
        #expect(paragraphStyle.paragraphSpacing == 14.25)
        #expect(kern == 7.5)
    }

    @Test func readingDefaultsUseUlyssesReferenceBodySize() {
        #expect(ReadingDefaults.fontSize == 15)
        #expect(ReadingDefaults.lineHeight == 1.62)
        #expect(ReadingDefaults.fontSizeOptions.first == 15)
        #expect(ReadingDefaults.lineHeightOptions.first == 1.62)
    }

    private static var tableRenderStyle: RenderStyle {
        RenderStyle(size: 17, fontFamily: nil, lineHeight: 1.6)
    }

    private static var ulyssesReferenceStyle: RenderStyle {
        RenderStyle(size: 15, fontFamily: nil, lineHeight: 1.62)
    }

    private static func renderTable(_ markdown: String) -> RenderedDocument {
        MarkdownRenderer.render(markdown, style: tableRenderStyle)
    }

    private static func renderUlyssesReference(_ markdown: String) -> RenderedDocument {
        MarkdownRenderer.render(markdown, style: ulyssesReferenceStyle)
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

    private static func font(in rendered: RenderedDocument, containing text: String) throws -> NSFont {
        let range = try range(of: text, in: rendered)
        let attribute = rendered.attributedString.attribute(.font,
                                                            at: range.location,
                                                            effectiveRange: nil)
        return try #require(attribute as? NSFont)
    }

    private static func fontWeight(_ font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? NSDictionary
        return traits?[NSFontDescriptor.TraitKey.weight] as? CGFloat ?? 0
    }

    private static func foregroundColor(in rendered: RenderedDocument, containing text: String) throws -> NSColor {
        let range = try range(of: text, in: rendered)
        let attribute = rendered.attributedString.attribute(.foregroundColor,
                                                            at: range.location,
                                                            effectiveRange: nil)
        return try #require(attribute as? NSColor)
    }

    private static func backgroundColor(in rendered: RenderedDocument, containing text: String) throws -> NSColor {
        let range = try range(of: text, in: rendered)
        let attribute = rendered.attributedString.attribute(.backgroundColor,
                                                            at: range.location,
                                                            effectiveRange: nil)
        return try #require(attribute as? NSColor)
    }

    private static func kern(in rendered: RenderedDocument, containing text: String) throws -> Double {
        let range = try range(of: text, in: rendered)
        let attribute = rendered.attributedString.attribute(.kern,
                                                            at: range.location,
                                                            effectiveRange: nil)
        return try #require(attribute as? Double)
    }

    private static func alpha(of color: NSColor) -> Double {
        Double((color.alphaComponent * 1_000).rounded() / 1_000)
    }

    private static func range(of text: String, in rendered: RenderedDocument) throws -> NSRange {
        let range = (rendered.attributedString.string as NSString).range(of: text)
        try #require(range.location != NSNotFound)
        return range
    }
}
