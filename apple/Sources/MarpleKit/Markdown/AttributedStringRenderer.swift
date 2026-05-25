import Foundation
import AppKit
import Markdown

// MARK: - Public types

/// Character range of a heading within the rendered NSAttributedString.
public struct HeadingAnchor: Equatable, Sendable {
    public let level: Int
    public let text: String
    public let range: NSRange
}

/// Result of rendering markdown to NSAttributedString.
public struct RenderedDocument {
    public let attributedString: NSAttributedString
    public let headings: [HeadingAnchor]
}

/// Font family for the reading column (mirrors ReadingFontFamily without SwiftUI import).
public enum MarkdownFontDesign: String, Equatable, Sendable, CaseIterable {
    case sans, serif, mono
}

/// Input parameters for rendering (Equatable via synthesized == on stored properties).
/// AppKit types (NSFont, NSColor, NSParagraphStyle) are computed lazily.
public struct RenderStyle: Equatable {
    public let size: Double
    public let design: MarkdownFontDesign
    public let lineHeight: Double

    public init(size: Double, design: MarkdownFontDesign, lineHeight: Double) {
        self.size = size
        self.design = design
        self.lineHeight = lineHeight
    }

    // MARK: Fonts

    var bodyFont: NSFont {
        switch design {
        case .sans:  return NSFont.systemFont(ofSize: size, weight: .regular)
        case .serif: return NSFont(name: "Songti SC", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .regular)
        case .mono:  return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    var codeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular)
    }

    var tableBodyFont: NSFont {
        switch design {
        case .sans:  return NSFont.systemFont(ofSize: size * 0.94, weight: .regular)
        case .serif: return NSFont(name: "Songti SC", size: size * 0.94)
            ?? NSFont.systemFont(ofSize: size * 0.94, weight: .regular)
        case .mono:  return NSFont.monospacedSystemFont(ofSize: size * 0.94, weight: .regular)
        }
    }

    var tableHeaderFont: NSFont {
        let bodyFont = tableBodyFont
        let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: descriptor, size: bodyFont.pointSize)
            ?? NSFont.systemFont(ofSize: size * 0.94, weight: .semibold)
    }

    func headingFont(level: Int) -> NSFont {
        let scale: CGFloat = [1.65, 1.35, 1.15, 1.0, 0.95, 0.9][min(level, 6) - 1]
        return NSFont.systemFont(ofSize: size * scale, weight: .bold)
    }

    // MARK: Colors

    var textColor: NSColor { .textColor }
    var linkColor: NSColor { .linkColor }
    var codeBackgroundColor: NSColor { .textBackgroundColor.withAlphaComponent(0.5) }
    var quoteTextColor: NSColor { .secondaryLabelColor }
    var tableBorderColor: NSColor { .separatorColor.withAlphaComponent(0.30) }
    var tableHeaderBorderColor: NSColor { .separatorColor.withAlphaComponent(0.7) }
    var tableHeaderBackgroundColor: NSColor { .textColor.withAlphaComponent(0.07) }
    var tableRowAlternateBackgroundColor: NSColor { .textColor.withAlphaComponent(0.035) }

    // MARK: Line spacing

    var lineSpacing: CGFloat { CGFloat(size * (lineHeight - 1.0)) }
    var tableLineSpacing: CGFloat { max(2, CGFloat(size * 0.16)) }

    // MARK: Paragraph styles

    var bodyParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        return ps
    }

    var codeParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        ps.headIndent = 16
        ps.firstLineHeadIndent = 16
        return ps
    }

    func quoteParagraphStyle(depth: Int = 1) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        let indent = CGFloat(20 * depth)
        ps.headIndent = indent
        ps.firstLineHeadIndent = indent
        return ps
    }

    func listParagraphStyle(depth: Int = 1) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        let indent = CGFloat(24 * depth)
        ps.headIndent = indent
        ps.firstLineHeadIndent = 0
        ps.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        return ps
    }

    var centerParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineSpacing = lineSpacing
        return ps
    }
}

// MARK: - Renderer entry point

public enum MarkdownRenderer {
    /// Render preprocessed markdown (wikilinks already converted to marple:// links)
    /// into an NSAttributedString with heading anchor metadata.
    public static func render(_ markdown: String, style: RenderStyle) -> RenderedDocument {
        let document = Document(parsing: markdown)
        let ctx = RenderContext(style: style)
        ctx.walk(document)
        return RenderedDocument(attributedString: ctx.attributed, headings: ctx.headings)
    }
}

// MARK: - Render context (private)

private final class RenderContext {
    let attributed = NSMutableAttributedString()
    let style: RenderStyle
    var headings: [HeadingAnchor] = []

    /// Current base font (body or heading — changed per block).
    var baseFont: NSFont
    /// Inline font traits pushed/popped by Strong/Emphasis.
    var traits: NSFontDescriptor.SymbolicTraits = []
    /// Active paragraph style for the current block.
    var ps: NSParagraphStyle
    /// Active link URL (non-nil when inside a Link element).
    var linkURL: String?

    var currentFont: NSFont {
        let desc = baseFont.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: baseFont.pointSize) ?? baseFont
    }

    init(style: RenderStyle) {
        self.style = style
        self.baseFont = style.bodyFont
        self.ps = style.bodyParagraphStyle
    }

    // MARK: Top-level walk

    func walk(_ markup: Markup) {
        for child in markup.children { visitBlock(child) }
    }

    // MARK: Block visitors

    private func visitBlock(_ markup: Markup) {
        switch markup {
        case let h as Heading:       visitHeading(h)
        case let p as Paragraph:     visitParagraph(p)
        case let c as CodeBlock:     visitCodeBlock(c)
        case let q as BlockQuote:    visitBlockQuote(q)
        case let l as UnorderedList: visitUnorderedList(l)
        case let l as OrderedList:   visitOrderedList(l)
        case is ThematicBreak:       visitThematicBreak()
        case let t as Table:         visitTable(t)
        case let h as HTMLBlock:
            append(h.rawHTML, color: .tertiaryLabelColor)
            newlines(2)
        default: break
        }
    }

    private func visitHeading(_ heading: Heading) {
        let start = attributed.length
        baseFont = style.headingFont(level: heading.level)
        traits = []
        ps = style.bodyParagraphStyle
        walkInlines(heading.children)
        let text = plainText(of: heading)
        headings.append(HeadingAnchor(
            level: heading.level,
            text: text,
            range: NSRange(location: start, length: attributed.length - start)
        ))
        newlines(2)
        baseFont = style.bodyFont
        traits = []
        ps = style.bodyParagraphStyle
    }

    private func visitParagraph(_ paragraph: Paragraph) {
        ps = style.bodyParagraphStyle
        walkInlines(paragraph.children)
        newlines(2)
    }

    private func visitCodeBlock(_ block: CodeBlock) {
        ps = style.codeParagraphStyle
        append(block.code, font: style.codeFont, bg: style.codeBackgroundColor)
        newlines(2)
        ps = style.bodyParagraphStyle
    }

    private func visitBlockQuote(_ quote: BlockQuote, depth: Int = 1) {
        ps = style.quoteParagraphStyle(depth: depth)
        for child in quote.children {
            if let p = child as? Paragraph {
                walkInlines(p.children)
                newlines(1)
            } else if let nested = child as? BlockQuote {
                visitBlockQuote(nested, depth: depth + 1)
            } else {
                visitBlock(child)
            }
        }
        newlines(1)
        ps = style.bodyParagraphStyle
    }

    private func visitUnorderedList(_ list: UnorderedList, depth: Int = 1) {
        ps = style.listParagraphStyle(depth: depth)
        for item in list.listItems {
            append("\u{2022} ", font: style.bodyFont)
            walkListItemChildren(item.children, depth: depth)
            newlines(1)
        }
        newlines(1)
        ps = style.bodyParagraphStyle
    }

    private func visitOrderedList(_ list: OrderedList, depth: Int = 1) {
        ps = style.listParagraphStyle(depth: depth)
        var n = list.startIndex
        for item in list.listItems {
            append("\(n). ", font: style.bodyFont)
            walkListItemChildren(item.children, depth: depth)
            newlines(1)
            n += 1
        }
        newlines(1)
        ps = style.bodyParagraphStyle
    }

    private func walkListItemChildren(_ children: MarkupChildren, depth: Int) {
        for child in children {
            if let p = child as? Paragraph {
                walkInlines(p.children)
            } else if let nested = child as? UnorderedList {
                visitUnorderedList(nested, depth: depth + 1)
            } else if let nested = child as? OrderedList {
                visitOrderedList(nested, depth: depth + 1)
            }
        }
    }

    private func visitThematicBreak() {
        ps = style.centerParagraphStyle
        append(String(repeating: "\u{2500}", count: 24), color: .tertiaryLabelColor)
        newlines(2)
        ps = style.bodyParagraphStyle
    }

    private func visitTable(_ table: Table) {
        let headerCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows.map { Array($0.cells) })
        let bodyColumnCount = bodyRows.reduce(0) { max($0, $1.count) }
        let columnCount = max(headerCells.count, bodyColumnCount)
        guard columnCount > 0 else { return }

        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.layoutAlgorithm = .fixedLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        let columnWidths = tableColumnWidthPercentages(headerCells: headerCells,
                                                       bodyRows: bodyRows,
                                                       columnCount: columnCount)

        for column in 0..<columnCount {
            visitTableCell(column < headerCells.count ? headerCells[column] : nil,
                           table: textTable,
                           row: 0,
                           column: column,
                           isHeader: true,
                           isAlternateRow: false,
                           columnWidthPercent: columnWidths[column])
        }

        for (rowOffset, rowCells) in bodyRows.enumerated() {
            for column in 0..<columnCount {
                visitTableCell(column < rowCells.count ? rowCells[column] : nil,
                               table: textTable,
                               row: rowOffset + 1,
                               column: column,
                               isHeader: false,
                               isAlternateRow: rowOffset % 2 == 1,
                               columnWidthPercent: columnWidths[column])
            }
        }

        newlines(1)
        ps = style.bodyParagraphStyle
    }

    /// Column widths driven by real text measurement (mirrors Reading.measure = 700).
    /// Each column is given at least the width of its widest unbreakable token (so Latin
    /// words and short CJK headers never break mid-word), then the remaining budget is
    /// shared in proportion to each column's natural single-line width.
    private func tableColumnWidthPercentages(headerCells: [Markup], bodyRows: [[Markup]], columnCount: Int) -> [CGFloat] {
        let referenceContentWidth: CGFloat = 700
        let cellHorizontalPadding: CGFloat = 20
        let budget = max(referenceContentWidth - CGFloat(columnCount) * cellHorizontalPadding, 1)
        let naturalCap = budget * 0.45

        let headerFont = style.tableHeaderFont
        let bodyFont = style.tableBodyFont
        var minWidths = [CGFloat](repeating: 0, count: columnCount)
        var naturalWidths = [CGFloat](repeating: 0, count: columnCount)

        for column in 0..<columnCount {
            if column < headerCells.count {
                let text = plainText(of: headerCells[column])
                minWidths[column] = max(minWidths[column], longestUnbreakableWidth(text, font: headerFont))
                naturalWidths[column] = max(naturalWidths[column], singleLineWidth(text, font: headerFont))
            }
            for rowCells in bodyRows where column < rowCells.count {
                let text = plainText(of: rowCells[column])
                minWidths[column] = max(minWidths[column], longestUnbreakableWidth(text, font: bodyFont))
                naturalWidths[column] = max(naturalWidths[column], singleLineWidth(text, font: bodyFont))
            }
            naturalWidths[column] = min(naturalWidths[column], naturalCap)
            minWidths[column] = min(minWidths[column], naturalWidths[column])
        }

        let sumMin = minWidths.reduce(0, +)
        let flex = zip(minWidths, naturalWidths).map { max($0.1 - $0.0, 0) }
        let sumFlex = flex.reduce(0, +)

        let widths: [CGFloat]
        if sumMin >= budget || sumFlex <= 0 {
            widths = minWidths
        } else {
            let extra = budget - sumMin
            widths = (0..<columnCount).map { minWidths[$0] + extra * flex[$0] / sumFlex }
        }

        let total = widths.reduce(0, +)
        guard total > 0 else { return Array(repeating: 100 / CGFloat(columnCount), count: columnCount) }
        return widths.map { $0 / total * 100 }
    }

    /// Width of `text` laid out on a single line.
    private func singleLineWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Width of the widest run the line-breaker won't split: whitespace and CJK
    /// boundaries allow breaks, so Latin words stay whole while CJK measures per char.
    private func longestUnbreakableWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        var maxWidth: CGFloat = 0
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            maxWidth = max(maxWidth, singleLineWidth(token, font: font))
            token = ""
        }
        for ch in text {
            if ch == " " || ch == "\t" || ch == "\n" {
                flush()
            } else if let scalar = ch.unicodeScalars.first, isCJKBreakable(scalar) {
                flush()
                maxWidth = max(maxWidth, singleLineWidth(String(ch), font: font))
            } else {
                token.append(ch)
            }
        }
        flush()
        return maxWidth
    }

    private func isCJKBreakable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols & punctuation
             0x3040...0x30FF,   // Hiragana & Katakana
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFFEF:   // halfwidth & fullwidth forms
            return true
        default:
            return false
        }
    }

    private func visitTableCell(_ cell: Markup?, table: NSTextTable, row: Int, column: Int, isHeader: Bool, isAlternateRow: Bool, columnWidthPercent: CGFloat) {
        let previousBaseFont = baseFont
        let previousTraits = traits
        let previousParagraphStyle = ps
        let previousLinkURL = linkURL

        baseFont = isHeader ? style.tableHeaderFont : style.tableBodyFont
        traits = []
        linkURL = nil
        ps = tableCellParagraphStyle(table: table,
                                     row: row,
                                     column: column,
                                     isHeader: isHeader,
                                     isAlternateRow: isAlternateRow,
                                     columnWidthPercent: columnWidthPercent)

        let start = attributed.length
        if let cell {
            walkInlines(cell.children)
        }
        if attributed.length == start {
            append("—", color: .tertiaryLabelColor)
        }
        newlines(1)

        baseFont = previousBaseFont
        traits = previousTraits
        ps = previousParagraphStyle
        linkURL = previousLinkURL
    }

    private func tableCellParagraphStyle(table: NSTextTable, row: Int, column: Int, isHeader: Bool, isAlternateRow: Bool, columnWidthPercent: CGFloat) -> NSParagraphStyle {
        let block = NSTextTableBlock(table: table,
                                     startingRow: row,
                                     rowSpan: 1,
                                     startingColumn: column,
                                     columnSpan: 1)
        block.setValue(columnWidthPercent, type: .percentageValueType, for: .width)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(0, type: .absoluteValueType, for: .border)
        block.setWidth(isHeader ? 1.0 : 0.5, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(isHeader ? style.tableHeaderBorderColor : style.tableBorderColor, for: .maxY)
        if isHeader {
            block.backgroundColor = style.tableHeaderBackgroundColor
        } else if isAlternateRow {
            block.backgroundColor = style.tableRowAlternateBackgroundColor
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = style.tableLineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.textBlocks = [block]
        return paragraphStyle
    }

    // MARK: Inline visitors

    private func walkInlines(_ children: MarkupChildren) {
        for child in children { visitInline(child) }
    }

    private func visitInline(_ markup: Markup) {
        switch markup {
        case let t as Text:
            let color: NSColor = linkURL != nil ? style.linkColor : style.textColor
            append(t.string, font: currentFont, color: color, link: linkURL)

        case let strong as Strong:
            traits.insert(.bold)
            walkInlines(strong.children)
            traits.remove(.bold)

        case let em as Emphasis:
            traits.insert(.italic)
            walkInlines(em.children)
            traits.remove(.italic)

        case let strikethrough as Strikethrough:
            let start = attributed.length
            walkInlines(strikethrough.children)
            attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                    range: NSRange(location: start, length: attributed.length - start))

        case let link as Link:
            let prev = linkURL
            linkURL = link.destination
            walkInlines(link.children)
            linkURL = prev

        case let code as InlineCode:
            append(code.code, font: style.codeFont, bg: style.codeBackgroundColor)

        case is SoftBreak:
            append(" ")

        case is LineBreak:
            newlines(1)

        case let img as Image:
            let alt = plainText(of: img)
            append(alt.isEmpty ? "[image]" : "[\(alt)]", color: .tertiaryLabelColor)

        case let html as InlineHTML:
            append(html.rawHTML, color: .tertiaryLabelColor)

        default:
            walkInlines(markup.children)
        }
    }

    // MARK: Append helpers

    private func append(_ text: String, font: NSFont? = nil, color: NSColor? = nil,
                        bg: NSColor? = nil, link: String? = nil) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? currentFont,
            .foregroundColor: color ?? style.textColor,
            .paragraphStyle: ps,
        ]
        if let bg { attrs[.backgroundColor] = bg }
        if let url = link {
            attrs[.link] = url
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        attributed.append(NSAttributedString(string: text, attributes: attrs))
    }

    private func newlines(_ n: Int) {
        attributed.append(NSAttributedString(
            string: String(repeating: "\n", count: n),
            attributes: [.paragraphStyle: ps]
        ))
    }

    // MARK: Text extraction

    /// Visible inline text (same logic as MarkdownModel.plainText).
    private func plainText(of markup: Markup) -> String {
        var s = ""
        collectText(markup, into: &s)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func collectText(_ markup: Markup, into s: inout String) {
        if let t = markup as? Text { s += t.string; return }
        if let c = markup as? InlineCode { s += c.code; return }
        if markup is SoftBreak || markup is LineBreak { s += " "; return }
        for child in markup.children { collectText(child, into: &s) }
    }
}
