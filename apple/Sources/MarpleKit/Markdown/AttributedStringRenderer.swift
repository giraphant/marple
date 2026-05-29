import Foundation
import AppKit
import CoreText
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

// MARK: - Self-drawn table chrome
//
// Tables nest a one-cell outer table (the card) around the real data table, so a
// single `RoundedCardBlock` draws one rounded card + border for the whole table.
// Overriding `NSTextBlock.drawBackground` lets us draw rounded corners and crisp
// hairlines with `NSBezierPath` while the cell text stays live (selection / ⌘F /
// wikilinks). See WWDC 2018 "TextKit Best Practices".

/// Outer wrapper block: draws the rounded card surface + border once for the table.
final class RoundedCardBlock: NSTextTableBlock {
    var fillColor: NSColor = .clear
    var borderColor: NSColor = .separatorColor
    var cornerRadius: CGFloat = 9

    // The frame from the most recent draw, so cells can clip their own fills/hairlines
    // to the card's rounded interior. The outer card block draws before the inner
    // cells, so this is populated by the time a cell draws.
    private(set) var lastFrame: NSRect = .zero

    // Drawn during NSTextView layout/draw, where NSAppearance.current is already the
    // view's effective appearance — so the dynamic NSColors resolve for light/dark.
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView,
                                 characterRange: NSRange, layoutManager: NSLayoutManager) {
        lastFrame = frameRect
        let rect = frameRect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        path.lineWidth = 1
        borderColor.setStroke()
        path.stroke()
    }

    /// The interior of the card, just inside the 1px border — cell fills and hairlines
    /// clip to this so they can never bleed past the rounded corners.
    func interiorClipPath() -> NSBezierPath {
        let rect = lastFrame.insetBy(dx: 1, dy: 1)
        let radius = max(cornerRadius - 1, 0)
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
}

/// Inner data cell: draws an optional header fill (rounded at the table's top
/// corners) and a faint hairline beneath body rows. Borders are all self-drawn.
final class TableCellBlock: NSTextTableBlock {
    var headerFillColor: NSColor?
    var rowSeparatorColor: NSColor?
    var cornerRadius: CGFloat = 9
    var roundTopLeft = false
    var roundTopRight = false
    weak var card: RoundedCardBlock?
    private(set) var lastFrame: NSRect = .zero

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView,
                                 characterRange: NSRange, layoutManager: NSLayoutManager) {
        lastFrame = frameRect
        let cardFrame = card?.lastFrame ?? .zero
        let hasCard = cardFrame != .zero

        // Clip to the card interior so the header fill and row hairlines take their
        // rounded corners directly from the card's own path — they can neither spill
        // past the border nor leave a gap at the corners.
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        if hasCard { card?.interiorClipPath().setClip() }

        if let fill = headerFillColor {
            // A plain band spanning to the card's edges (where this column touches
            // them); the clip above carves the rounded top corners to match the card.
            let left = (hasCard && roundTopLeft) ? cardFrame.minX : frameRect.minX
            let right = (hasCard && roundTopRight) ? cardFrame.maxX : frameRect.maxX
            let top = hasCard ? cardFrame.minY : frameRect.minY
            let band = NSRect(x: left, y: top, width: right - left, height: frameRect.maxY - top)
            fill.setFill()
            band.fill()
        }
        if let separator = rowSeparatorColor {
            let y = frameRect.maxY - 0.5
            let line = NSBezierPath()
            line.move(to: NSPoint(x: frameRect.minX, y: y))
            line.line(to: NSPoint(x: frameRect.maxX, y: y))
            line.lineWidth = 1
            separator.setStroke()
            line.stroke()
        }
    }
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
        NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
    }

    var tableBodyFont: NSFont {
        let base: NSFont
        switch design {
        case .sans:  base = NSFont.systemFont(ofSize: size * 0.90, weight: .regular)
        case .serif: base = NSFont(name: "Songti SC", size: size * 0.90)
            ?? NSFont.systemFont(ofSize: size * 0.90, weight: .regular)
        case .mono:  base = NSFont.monospacedSystemFont(ofSize: size * 0.90, weight: .regular)
        }
        return Self.withMonospacedDigits(base)
    }

    var tableHeaderFont: NSFont {
        let bodyFont = tableBodyFont
        let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: descriptor, size: bodyFont.pointSize)
            ?? NSFont.systemFont(ofSize: size * 0.90, weight: .semibold)
    }

    /// Tabular (monospaced) figures so digits align vertically across table rows.
    private static func withMonospacedDigits(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    func headingFont(level: Int) -> NSFont {
        let clamped = min(level, 6) - 1
        let scale: CGFloat = [1.8, 1.5, 1.25, 1.125, 1.0, 1.0][clamped]
        let weight: NSFont.Weight = [.bold, .semibold, .medium, .medium, .regular, .regular][clamped]
        return NSFont.systemFont(ofSize: size * scale, weight: weight)
    }

    // MARK: Colors

    var textColor: NSColor { .textColor }
    var linkColor: NSColor { .linkColor }
    var codeBackgroundColor: NSColor { .textColor.withAlphaComponent(0.035) }
    var quoteTextColor: NSColor { .secondaryLabelColor }
    var separatorTextColor: NSColor { .tertiaryLabelColor }
    var tableCornerRadius: CGFloat { 9 }
    var tableCardFillColor: NSColor { .textColor.withAlphaComponent(0.022) }
    var tableCardBorderColor: NSColor { .separatorColor }
    var tableHeaderFillColor: NSColor { .textColor.withAlphaComponent(0.04) }
    var tableRowSeparatorColor: NSColor { .textColor.withAlphaComponent(0.05) }
    var tableHeaderTextColor: NSColor { .secondaryLabelColor }
    var tableHeaderKern: CGFloat { CGFloat(size * 0.03) }

    func headingColor(level: Int) -> NSColor {
        level >= 6 ? .secondaryLabelColor : textColor
    }

    // MARK: Line spacing

    var lineSpacing: CGFloat { CGFloat(size * (lineHeight - 1.0)) }
    var tableLineSpacing: CGFloat { max(2, CGFloat(size * 0.16)) }

    // MARK: Paragraph styles

    var bodyParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        ps.paragraphSpacing = CGFloat(size * 0.95)
        return ps
    }

    func headingParagraphStyle(level _: Int, followsHeading: Bool = false, followsContent: Bool = false) -> NSParagraphStyle {
        let before: CGFloat = followsHeading ? 0 : (followsContent ? CGFloat(size * 0.25) : 0)
        let after: CGFloat = CGFloat(size * 0.4)
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        ps.paragraphSpacingBefore = before
        ps.paragraphSpacing = after
        return ps
    }

    var codeParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = max(lineSpacing, CGFloat(size * 0.55))
        ps.headIndent = 16
        ps.firstLineHeadIndent = 16
        ps.paragraphSpacingBefore = 24
        ps.paragraphSpacing = 24
        return ps
    }

    func quoteParagraphStyle(depth: Int = 1) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        let indent = CGFloat(28 * depth)
        ps.headIndent = indent
        ps.firstLineHeadIndent = indent
        ps.paragraphSpacingBefore = 24
        ps.paragraphSpacing = 24
        return ps
    }

    func listParagraphStyle(depth: Int = 1) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        ps.paragraphSpacing = CGFloat(size * 0.4)
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
        ps.paragraphSpacingBefore = CGFloat(size * 0.95)
        ps.paragraphSpacing = CGFloat(size * 0.95)
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
    private enum PreviousBlock {
        case heading, content
    }

    let attributed = NSMutableAttributedString()
    let style: RenderStyle
    var headings: [HeadingAnchor] = []

    /// Current base font (body or heading — changed per block).
    var baseFont: NSFont
    /// Inline font traits pushed/popped by Strong/Emphasis.
    var traits: NSFontDescriptor.SymbolicTraits = []
    /// Active paragraph style for the current block.
    var ps: NSParagraphStyle
    /// Active block text color, used for quotes and dim headings.
    var activeTextColor: NSColor?
    /// Active kerning (letter-spacing) for the current run; used for table headers.
    var activeKern: CGFloat?
    /// Active link URL (non-nil when inside a Link element).
    var linkURL: String?

    var currentFont: NSFont {
        guard !traits.isEmpty else { return baseFont }
        let combinedTraits = baseFont.fontDescriptor.symbolicTraits.union(traits)
        let desc = baseFont.fontDescriptor.withSymbolicTraits(combinedTraits)
        return NSFont(descriptor: desc, size: baseFont.pointSize) ?? baseFont
    }

    init(style: RenderStyle) {
        self.style = style
        self.baseFont = style.bodyFont
        self.ps = style.bodyParagraphStyle
    }

    // MARK: Top-level walk

    func walk(_ markup: Markup) {
        var previousBlock: PreviousBlock?
        for child in markup.children {
            if let emittedBlock = visitBlock(child, previousBlock: previousBlock) {
                previousBlock = emittedBlock
            }
        }
    }

    // MARK: Block visitors

    private func visitBlock(_ markup: Markup, previousBlock: PreviousBlock? = nil) -> PreviousBlock? {
        switch markup {
        case let h as Heading:
            visitHeading(h, previousBlock: previousBlock)
            return .heading
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
        default: return nil
        }
        return .content
    }

    private func visitHeading(_ heading: Heading, previousBlock: PreviousBlock? = nil) {
        let start = attributed.length
        baseFont = style.headingFont(level: heading.level)
        traits = []
        ps = style.headingParagraphStyle(level: heading.level,
                                         followsHeading: previousBlock == .heading,
                                         followsContent: previousBlock == .content)
        activeTextColor = style.headingColor(level: heading.level)
        walkInlines(heading.children)
        let text = plainText(of: heading)
        headings.append(HeadingAnchor(
            level: heading.level,
            text: text,
            range: NSRange(location: start, length: attributed.length - start)
        ))
        newlines(1)
        baseFont = style.bodyFont
        traits = []
        ps = style.bodyParagraphStyle
        activeTextColor = nil
    }

    private func visitParagraph(_ paragraph: Paragraph) {
        ps = style.bodyParagraphStyle
        walkInlines(paragraph.children)
        newlines(1)
    }

    private func visitCodeBlock(_ block: CodeBlock) {
        ps = style.codeParagraphStyle
        append(block.code, font: style.codeFont, bg: style.codeBackgroundColor)
        newlines(1)
        ps = style.bodyParagraphStyle
    }

    private func visitBlockQuote(_ quote: BlockQuote, depth: Int = 1) {
        let previousTextColor = activeTextColor
        ps = style.quoteParagraphStyle(depth: depth)
        activeTextColor = style.quoteTextColor
        for child in quote.children {
            if let p = child as? Paragraph {
                walkInlines(p.children)
                newlines(1)
            } else if let nested = child as? BlockQuote {
                visitBlockQuote(nested, depth: depth + 1)
            } else {
                _ = visitBlock(child)
            }
        }
        ps = style.bodyParagraphStyle
        activeTextColor = previousTextColor
    }

    private func visitUnorderedList(_ list: UnorderedList, depth: Int = 1) {
        ps = style.listParagraphStyle(depth: depth)
        for item in list.listItems {
            append("· ", font: style.bodyFont, color: style.quoteTextColor)
            walkListItemChildren(item.children, depth: depth)
            newlines(1)
        }
        ps = style.bodyParagraphStyle
    }

    private func visitOrderedList(_ list: OrderedList, depth: Int = 1) {
        ps = style.listParagraphStyle(depth: depth)
        var n = list.startIndex
        for item in list.listItems {
            append("\(n). ", font: style.codeFont, color: style.quoteTextColor)
            walkListItemChildren(item.children, depth: depth)
            newlines(1)
            n += 1
        }
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
        append("· · ·", color: style.separatorTextColor, kern: CGFloat(sizeDependentKern()))
        newlines(1)
        ps = style.bodyParagraphStyle
    }

    private func sizeDependentKern() -> Double {
        style.size * 0.5
    }

    private func visitTable(_ table: Table) {
        let headerCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows.map { Array($0.cells) })
        let bodyColumnCount = bodyRows.reduce(0) { max($0, $1.count) }
        let columnCount = max(headerCells.count, bodyColumnCount)
        guard columnCount > 0 else { return }

        // Outer one-cell table whose shared block draws the rounded card + border.
        let outerTable = NSTextTable()
        outerTable.numberOfColumns = 1
        outerTable.layoutAlgorithm = .fixedLayoutAlgorithm
        outerTable.collapsesBorders = true
        let card = RoundedCardBlock(table: outerTable, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        card.setValue(100, type: .percentageValueType, for: .width)
        card.fillColor = style.tableCardFillColor
        card.borderColor = style.tableCardBorderColor
        card.cornerRadius = style.tableCornerRadius
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            card.setWidth(2, type: .absoluteValueType, for: .padding, edge: edge)
        }

        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.layoutAlgorithm = .fixedLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        let columnWidths = tableColumnWidthPercentages(headerCells: headerCells,
                                                       bodyRows: bodyRows,
                                                       columnCount: columnCount)
        let columnAlignments = table.columnAlignments
        let effectiveAlignments = (0..<columnCount).map { column -> Table.ColumnAlignment? in
            if column < columnAlignments.count, let explicit = columnAlignments[column] { return explicit }
            return isNumericColumn(column, bodyRows: bodyRows) ? .right : nil
        }
        let lastRow = bodyRows.count

        for column in 0..<columnCount {
            visitTableCell(column < headerCells.count ? headerCells[column] : nil,
                           card: card,
                           table: textTable,
                           row: 0,
                           column: column,
                           columnCount: columnCount,
                           isHeader: true,
                           isLastRow: lastRow == 0,
                           columnWidthPercent: columnWidths[column],
                           columnAlignment: effectiveAlignments[column])
        }

        for (rowOffset, rowCells) in bodyRows.enumerated() {
            for column in 0..<columnCount {
                visitTableCell(column < rowCells.count ? rowCells[column] : nil,
                               card: card,
                               table: textTable,
                               row: rowOffset + 1,
                               column: column,
                               columnCount: columnCount,
                               isHeader: false,
                               isLastRow: rowOffset + 1 == lastRow,
                               columnWidthPercent: columnWidths[column],
                               columnAlignment: effectiveAlignments[column])
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
        let cellHorizontalPadding: CGFloat = 24
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

    /// A column reads as numeric when every non-empty body cell parses as a number,
    /// so it can be right-aligned even when the Markdown gave no alignment marker.
    private func isNumericColumn(_ column: Int, bodyRows: [[Markup]]) -> Bool {
        var sawNumber = false
        for rowCells in bodyRows where column < rowCells.count {
            let text = plainText(of: rowCells[column]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard Self.isNumericToken(text) else { return false }
            sawNumber = true
        }
        return sawNumber
    }

    /// Lenient numeric test: tolerates currency, percent, thousands separators and
    /// accounting-style parentheses before checking the remainder parses as a Double.
    private static func isNumericToken(_ raw: String) -> Bool {
        var token = raw
        if token.hasPrefix("(") && token.hasSuffix(")") {
            token = String(token.dropFirst().dropLast())
        }
        let decorations = Set("$€£¥%, ")
        token = String(token.filter { !decorations.contains($0) })
        guard !token.isEmpty else { return false }
        return Double(token) != nil
    }

    private func visitTableCell(_ cell: Markup?, card: RoundedCardBlock, table: NSTextTable, row: Int, column: Int, columnCount: Int, isHeader: Bool, isLastRow: Bool, columnWidthPercent: CGFloat, columnAlignment: Table.ColumnAlignment?) {
        let previousBaseFont = baseFont
        let previousTraits = traits
        let previousParagraphStyle = ps
        let previousTextColor = activeTextColor
        let previousKern = activeKern
        let previousLinkURL = linkURL

        baseFont = isHeader ? style.tableHeaderFont : style.tableBodyFont
        traits = []
        activeTextColor = isHeader ? style.tableHeaderTextColor : previousTextColor
        activeKern = isHeader ? style.tableHeaderKern : nil
        linkURL = nil
        ps = tableCellParagraphStyle(card: card,
                                     table: table,
                                     row: row,
                                     column: column,
                                     columnCount: columnCount,
                                     isHeader: isHeader,
                                     isLastRow: isLastRow,
                                     columnWidthPercent: columnWidthPercent,
                                     columnAlignment: columnAlignment)

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
        activeTextColor = previousTextColor
        activeKern = previousKern
        linkURL = previousLinkURL
    }

    private func tableCellParagraphStyle(card: RoundedCardBlock, table: NSTextTable, row: Int, column: Int, columnCount: Int, isHeader: Bool, isLastRow: Bool, columnWidthPercent: CGFloat, columnAlignment: Table.ColumnAlignment?) -> NSParagraphStyle {
        let block = TableCellBlock(table: table,
                                   startingRow: row,
                                   rowSpan: 1,
                                   startingColumn: column,
                                   columnSpan: 1)
        block.setValue(columnWidthPercent, type: .percentageValueType, for: .width)
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(isHeader ? 14 : 11, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(isHeader ? 18 : 11, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(0, type: .absoluteValueType, for: .border)
        block.cornerRadius = style.tableCornerRadius
        block.card = card
        if !isHeader {
            block.verticalAlignment = .middleAlignment
        }

        // The card draws the outer frame; cells only add a whisper header fill
        // (rounded at the table's top corners) and faint hairlines between rows.
        if isHeader {
            block.headerFillColor = style.tableHeaderFillColor
            block.roundTopLeft = column == 0
            block.roundTopRight = column == columnCount - 1
            block.rowSeparatorColor = style.tableRowSeparatorColor
        } else if !isLastRow {
            block.rowSeparatorColor = style.tableRowSeparatorColor
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = textAlignment(for: columnAlignment)
        paragraphStyle.lineSpacing = style.tableLineSpacing
        paragraphStyle.paragraphSpacingBefore = isHeader ? 16 : 0
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.textBlocks = [card, block]
        return paragraphStyle
    }

    private func textAlignment(for columnAlignment: Table.ColumnAlignment?) -> NSTextAlignment {
        switch columnAlignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case nil: return .natural
        }
    }

    // MARK: Inline visitors

    private func walkInlines(_ children: MarkupChildren) {
        for child in children { visitInline(child) }
    }

    private func visitInline(_ markup: Markup) {
        switch markup {
        case let t as Text:
            let color: NSColor = linkURL != nil ? style.linkColor : (activeTextColor ?? style.textColor)
            append(t.string, font: currentFont, color: color, link: linkURL, kern: activeKern)

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
                        bg: NSColor? = nil, link: String? = nil, kern: CGFloat? = nil) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? currentFont,
            .foregroundColor: color ?? activeTextColor ?? style.textColor,
            .paragraphStyle: ps,
        ]
        if let bg { attrs[.backgroundColor] = bg }
        if let kern { attrs[.kern] = kern }
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
