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

/// Input parameters for rendering (Equatable via synthesized == on stored properties).
/// AppKit types (NSFont, NSColor, NSParagraphStyle) are computed lazily.
public struct RenderStyle: Equatable {
    public let size: Double
    /// System font family for body/headings (nil = system font, i.e. 苹方 for CJK).
    /// Code blocks always stay monospaced regardless.
    public let fontFamily: String?
    /// Intended body weight. Traditional high-contrast 宋体 render faint on screen
    /// (thin horizontals); a heavier body holds up for long reading — resolved to a
    /// real cut where the family has one, light synthesis where it doesn't. Each family
    /// names/orders its weights differently, so this is set per-font, not a flag.
    public let bodyWeight: NSFont.Weight
    public let lineHeight: Double
    /// CJK letter-spacing as a fraction of the em; applied as `size * letterSpacing`
    /// to 中文 glyphs only (see `bodyKern`). 0 = packed (system default), no Latin effect.
    public let letterSpacing: Double

    public init(size: Double, fontFamily: String?, bodyWeight: NSFont.Weight = .regular,
                letterSpacing: Double = 0, lineHeight: Double) {
        self.size = size
        self.fontFamily = fontFamily
        self.bodyWeight = bodyWeight
        self.letterSpacing = letterSpacing
        self.lineHeight = lineHeight
    }

    // MARK: Fonts

    /// Resolve a real weight cut from the chosen family. `NSFontManager` returns the
    /// nearest *actual* member for a given weight — no faux-bold synthesis — which is
    /// the whole point: many CJK families ship one file per weight. Falls back to the
    /// system font (its CJK face is 苹方) when no family is chosen or it won't resolve.
    func font(_ size: Double, weight: NSFont.Weight) -> NSFont {
        if let fontFamily {
            if let f = NSFontManager.shared.font(
                withFamily: fontFamily, traits: [], weight: Self.managerWeight(weight), size: size) {
                return f
            }
            if let f = NSFont(name: fontFamily, size: size) { return f }
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// `NSFont.Weight` → `NSFontManager`'s 0–15 weight scale (regular≈5, bold≈9).
    static func managerWeight(_ weight: NSFont.Weight) -> Int {
        switch weight {
        case .ultraLight: return 2
        case .thin, .light: return 3
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        case .black: return 12
        default: return 5   // .regular and anything unmapped
        }
    }

    var bodyFont: NSFont { font(size, weight: bodyWeight) }

    var codeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
    }

    var tableBodyFont: NSFont { font(size * 0.90, weight: bodyWeight) }

    var tableHeaderFont: NSFont { font(size * 0.90, weight: .semibold) }

    func headingWeight(level: Int) -> NSFont.Weight {
        [.bold, .semibold, .medium, .medium, .regular, .regular][min(level, 6) - 1]
    }

    func headingFont(level: Int) -> NSFont {
        let clamped = min(level, 6) - 1
        let scale: Double = [1.8, 1.5, 1.25, 1.125, 1.0, 1.0][clamped]
        return font(size * scale, weight: headingWeight(level: level))
    }

    /// Synthetic-bold stroke (negative `.strokeWidth` = fill+stroke in the text color)
    /// for families lacking a real heavier cut: when the resolved face is lighter than
    /// `target`, thicken strokes in proportion to the weight gap. Returns nil for the
    /// system font and whenever a real weight cut already covers the target — so 苹方
    /// and real-weight families (霞鹜文楷) are byte-for-byte unaffected.
    func synthStroke(of resolved: NSFont, target: NSFont.Weight) -> CGFloat? {
        guard fontFamily != nil else { return nil }
        let deficit = Self.managerWeight(target) - NSFontManager.shared.weight(of: resolved)
        guard deficit > 0 else { return nil }
        return -CGFloat(deficit) * 1.1
    }

    // MARK: Colors

    var textColor: NSColor { .textColor }
    var linkColor: NSColor { .linkColor }
    var codeBackgroundColor: NSColor { .textColor.withAlphaComponent(0.035) }
    var quoteTextColor: NSColor { .secondaryLabelColor }
    var separatorTextColor: NSColor { .tertiaryLabelColor }
    var tableBorderColor: NSColor { .separatorColor.withAlphaComponent(0.24) }
    var tableHeaderBorderColor: NSColor { .separatorColor.withAlphaComponent(0.48) }
    var tableOuterBorderColor: NSColor { .separatorColor.withAlphaComponent(0.40) }
    var tableHeaderBackgroundColor: NSColor { .textColor.withAlphaComponent(0.04) }
    var tableHeaderTextColor: NSColor { .secondaryLabelColor }
    var tableHeaderKern: CGFloat { CGFloat(size * 0.03) }

    func headingColor(level: Int) -> NSColor {
        level >= 6 ? .secondaryLabelColor : textColor
    }

    // MARK: Line spacing

    var lineSpacing: CGFloat { CGFloat(size * (lineHeight - 1.0)) }
    var tableLineSpacing: CGFloat { max(2, CGFloat(size * 0.16)) }

    /// Tracking added after CJK glyphs in body/inline runs (see `applyCJKKern`). Zero
    /// packs 中文 tighter than Ulysses-style columns; a fraction of the em restores the
    /// horizontal breathing room. Driven by the user's 字间距 setting (`letterSpacing`).
    var bodyKern: CGFloat { CGFloat(size * letterSpacing) }

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
    /// Intended weight of the current block's base — what the design *asks for*, which
    /// may exceed what the chosen face actually provides (drives synthetic bold).
    var baseWeight: NSFont.Weight = .regular
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

    /// Synthetic-bold stroke for the current run: the block's intended weight, bumped
    /// to bold when inside `**…**`. Nil unless the chosen face falls short of it.
    var currentStroke: CGFloat? {
        var target = baseWeight
        if traits.contains(.bold),
           RenderStyle.managerWeight(target) < RenderStyle.managerWeight(.bold) {
            target = .bold
        }
        return style.synthStroke(of: currentFont, target: target)
    }

    init(style: RenderStyle) {
        self.style = style
        self.baseFont = style.bodyFont
        self.baseWeight = style.bodyWeight
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
        baseWeight = style.headingWeight(level: heading.level)
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
        baseWeight = style.bodyWeight
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

        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.layoutAlgorithm = .fixedLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        let columnWidths = tableColumnWidthPercentages(headerCells: headerCells,
                                                       bodyRows: bodyRows,
                                                       columnCount: columnCount)
        let columnAlignments = table.columnAlignments
        let lastRow = bodyRows.count

        for column in 0..<columnCount {
            visitTableCell(column < headerCells.count ? headerCells[column] : nil,
                           table: textTable,
                           row: 0,
                           column: column,
                           columnCount: columnCount,
                           isHeader: true,
                           isLastRow: lastRow == 0,
                           columnWidthPercent: columnWidths[column],
                           columnAlignment: column < columnAlignments.count ? columnAlignments[column] : nil)
        }

        for (rowOffset, rowCells) in bodyRows.enumerated() {
            for column in 0..<columnCount {
                visitTableCell(column < rowCells.count ? rowCells[column] : nil,
                               table: textTable,
                               row: rowOffset + 1,
                               column: column,
                               columnCount: columnCount,
                               isHeader: false,
                               isLastRow: rowOffset + 1 == lastRow,
                               columnWidthPercent: columnWidths[column],
                               columnAlignment: column < columnAlignments.count ? columnAlignments[column] : nil)
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

    private func visitTableCell(_ cell: Markup?, table: NSTextTable, row: Int, column: Int, columnCount: Int, isHeader: Bool, isLastRow: Bool, columnWidthPercent: CGFloat, columnAlignment: Table.ColumnAlignment?) {
        let previousBaseFont = baseFont
        let previousBaseWeight = baseWeight
        let previousTraits = traits
        let previousParagraphStyle = ps
        let previousTextColor = activeTextColor
        let previousKern = activeKern
        let previousLinkURL = linkURL

        baseFont = isHeader ? style.tableHeaderFont : style.tableBodyFont
        baseWeight = isHeader ? .semibold : style.bodyWeight
        traits = []
        activeTextColor = isHeader ? style.tableHeaderTextColor : previousTextColor
        activeKern = isHeader ? style.tableHeaderKern : nil
        linkURL = nil
        ps = tableCellParagraphStyle(table: table,
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
        baseWeight = previousBaseWeight
        traits = previousTraits
        ps = previousParagraphStyle
        activeTextColor = previousTextColor
        activeKern = previousKern
        linkURL = previousLinkURL
    }

    private func tableCellParagraphStyle(table: NSTextTable, row: Int, column: Int, columnCount: Int, isHeader: Bool, isLastRow: Bool, columnWidthPercent: CGFloat, columnAlignment: Table.ColumnAlignment?) -> NSParagraphStyle {
        let block = NSTextTableBlock(table: table,
                                     startingRow: row,
                                     rowSpan: 1,
                                     startingColumn: column,
                                     columnSpan: 1)
        block.setValue(columnWidthPercent, type: .percentageValueType, for: .width)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(7, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(0, type: .absoluteValueType, for: .border)

        // Horizontal rules: outer frame top/bottom, stronger rule under the header,
        // faint hairlines between body rows.
        if row == 0 {
            block.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .minY)
            block.setBorderColor(style.tableOuterBorderColor, for: .minY)
        }
        block.setWidth(isHeader || isLastRow ? 0.75 : 0.5, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(isLastRow ? style.tableOuterBorderColor : (isHeader ? style.tableHeaderBorderColor : style.tableBorderColor), for: .maxY)

        // Vertical rules: outer frame on the leading/trailing columns, faint inner
        // hairlines between columns (collapsed against the neighbour's edge).
        block.setWidth(column == 0 ? 0.75 : 0.5, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(column == 0 ? style.tableOuterBorderColor : style.tableBorderColor, for: .minX)
        if column == columnCount - 1 {
            block.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxX)
            block.setBorderColor(style.tableOuterBorderColor, for: .maxX)
        }

        if isHeader {
            block.backgroundColor = style.tableHeaderBackgroundColor
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = textAlignment(for: columnAlignment)
        paragraphStyle.lineSpacing = style.tableLineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.textBlocks = [block]
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
            let start = attributed.length
            // Table headers carry an explicit uniform kern; elsewhere apply tracking
            // only to CJK glyphs (Latin reads well untouched — only 中文 packs tight).
            append(t.string, font: currentFont, color: color, link: linkURL,
                   kern: activeKern, stroke: currentStroke)
            if activeKern == nil, style.bodyKern > 0 {
                applyCJKKern(t.string, from: start, kern: style.bodyKern)
            }

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
                        bg: NSColor? = nil, link: String? = nil, kern: CGFloat? = nil,
                        stroke: CGFloat? = nil) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? currentFont,
            .foregroundColor: color ?? activeTextColor ?? style.textColor,
            .paragraphStyle: ps,
        ]
        if let bg { attrs[.backgroundColor] = bg }
        if let kern { attrs[.kern] = kern }
        if let stroke { attrs[.strokeWidth] = stroke }
        if let url = link {
            attrs[.link] = url
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        attributed.append(NSAttributedString(string: text, attributes: attrs))
    }

    /// Add letter-spacing only to the CJK glyphs of a run already appended at `start`.
    /// `.kern` adds trailing advance per character, so applying it to Han/CJK scalars
    /// loosens 中文 (incl. its boundary with Latin) while leaving Latin words untouched.
    private func applyCJKKern(_ string: String, from start: Int, kern: CGFloat) {
        var offset = start
        for ch in string {
            let len = ch.utf16.count
            if ch.isCJK {
                attributed.addAttribute(.kern, value: kern, range: NSRange(location: offset, length: len))
            }
            offset += len
        }
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

private extension Character {
    /// True for CJK ideographs and CJK/fullwidth punctuation — the glyphs that pack
    /// tight without tracking. Latin/ASCII stays false so it reads at its natural spacing.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F,   // CJK symbols & punctuation （。、「」…）
                 0x3400...0x4DBF,   // CJK Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0xFF00...0xFFEF,   // Fullwidth forms （，！？fullwidth punctuation）
                 0x20000...0x2A6DF: // CJK Extension B
                return true
            default:
                return false
            }
        }
    }
}
