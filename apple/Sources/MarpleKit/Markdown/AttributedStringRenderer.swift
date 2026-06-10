import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
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

// MARK: - Self-drawn table chrome
//
// Tables nest a one-cell outer table (the card) around the real data table, so a
// single `RoundedCardBlock` draws one rounded card + border for the whole table.
// Overriding `NSTextBlock.drawBackground` lets us draw rounded corners and crisp
// hairlines with `NSBezierPath` while the cell text stays live (selection / ⌘F /
// wikilinks). See WWDC 2018 "TextKit Best Practices".

// NSTextTable / NSTextTableBlock are AppKit-only (no UIKit equivalent), so the
// self-drawn table chrome compiles on macOS only. iOS falls back to plain stacked
// text in `visitTable`.
#if canImport(AppKit)

/// Outer wrapper block: draws the rounded card surface + border once for the table.
final class RoundedCardBlock: NSTextTableBlock {
    var fillColor: PlatformColor = .clear
    var borderColor: PlatformColor = .separatorColor
    var cornerRadius: CGFloat = 9

    // The frame from the most recent draw, so cells can clip their own fills/hairlines
    // to the card's rounded interior. The outer card block draws before the inner
    // cells, so this is populated by the time a cell draws.
    private(set) var lastFrame: CGRect = .zero

    // Drawn during NSTextView layout/draw, where NSAppearance.current is already the
    // view's effective appearance — so the dynamic NSColors resolve for light/dark.
    override func drawBackground(withFrame frameRect: CGRect, in controlView: PlatformView,
                                 characterRange: NSRange, layoutManager: NSLayoutManager) {
        lastFrame = frameRect
        let rect = frameRect.insetBy(dx: 0.5, dy: 0.5)
        #if canImport(AppKit)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        path.lineWidth = 1
        borderColor.setStroke()
        path.stroke()
        #elseif canImport(UIKit)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        path.lineWidth = 1
        borderColor.setStroke()
        path.stroke()
        #endif
    }

    /// The interior of the card, just inside the 1px border — cell fills and hairlines
    /// clip to this so they can never bleed past the rounded corners.
    func interiorClipPath() -> PlatformBezierPath {
        let rect = lastFrame.insetBy(dx: 1, dy: 1)
        let radius = max(cornerRadius - 1, 0)
        #if canImport(AppKit)
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        #elseif canImport(UIKit)
        return UIBezierPath(roundedRect: rect, cornerRadius: radius)
        #endif
    }
}

/// Inner data cell: draws an optional header fill (rounded at the table's top
/// corners) and a faint hairline beneath body rows. Borders are all self-drawn.
final class TableCellBlock: NSTextTableBlock {
    var headerFillColor: PlatformColor?
    var rowSeparatorColor: PlatformColor?
    var cornerRadius: CGFloat = 9
    var roundTopLeft = false
    var roundTopRight = false
    weak var card: RoundedCardBlock?
    private(set) var lastFrame: CGRect = .zero

    override func drawBackground(withFrame frameRect: CGRect, in controlView: PlatformView,
                                 characterRange: NSRange, layoutManager: NSLayoutManager) {
        lastFrame = frameRect
        let cardFrame = card?.lastFrame ?? .zero
        let hasCard = cardFrame != .zero

        // Clip to the card interior so the header fill and row hairlines take their
        // rounded corners directly from the card's own path — they can neither spill
        // past the border nor leave a gap at the corners.
        #if canImport(AppKit)
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        if hasCard { card?.interiorClipPath().setClip() }
        #elseif canImport(UIKit)
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        defer { ctx?.restoreGState() }
        if hasCard { card?.interiorClipPath().addClip() }
        #endif

        if let fill = headerFillColor {
            // A plain band spanning to the card's edges (where this column touches
            // them); the clip above carves the rounded top corners to match the card.
            let left = (hasCard && roundTopLeft) ? cardFrame.minX : frameRect.minX
            let right = (hasCard && roundTopRight) ? cardFrame.maxX : frameRect.maxX
            let top = hasCard ? cardFrame.minY : frameRect.minY
            let band = CGRect(x: left, y: top, width: right - left, height: frameRect.maxY - top)
            fill.setFill()
            #if canImport(AppKit)
            band.fill()
            #elseif canImport(UIKit)
            UIBezierPath(rect: band).fill()
            #endif
        }
        if let separator = rowSeparatorColor {
            let y = frameRect.maxY - 0.5
            let line = PlatformBezierPath()
            #if canImport(AppKit)
            line.move(to: NSPoint(x: frameRect.minX, y: y))
            line.line(to: NSPoint(x: frameRect.maxX, y: y))
            #elseif canImport(UIKit)
            line.move(to: CGPoint(x: frameRect.minX, y: y))
            line.addLine(to: CGPoint(x: frameRect.maxX, y: y))
            #endif
            line.lineWidth = 1
            separator.setStroke()
            line.stroke()
        }
    }
}

#endif

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
    public let bodyWeight: PlatformFont.Weight
    public let lineHeight: Double
    /// CJK letter-spacing as a fraction of the em; applied as `size * letterSpacing`
    /// to 中文 glyphs only (see `bodyKern`). 0 = packed (system default), no Latin effect.
    public let letterSpacing: Double

    public init(size: Double, fontFamily: String?, bodyWeight: PlatformFont.Weight = .regular,
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
    func font(_ size: Double, weight: PlatformFont.Weight) -> PlatformFont {
        if let fontFamily {
            #if canImport(AppKit)
            if let f = NSFontManager.shared.font(
                withFamily: fontFamily, traits: [], weight: Self.managerWeight(weight), size: size) {
                return f
            }
            if let f = NSFont(name: fontFamily, size: size) { return f }
            #elseif canImport(UIKit)
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let desc = base.fontDescriptor.withFamily(fontFamily)
                .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
            let resolved = UIFont(descriptor: desc, size: size)
            if resolved.familyName == fontFamily { return resolved }
            if let f = UIFont(name: fontFamily, size: size) { return f }
            #endif
        }
        return PlatformFont.systemFont(ofSize: size, weight: weight)
    }

    /// `NSFont.Weight` → `NSFontManager`'s 0–15 weight scale (regular≈5, bold≈9).
    static func managerWeight(_ weight: PlatformFont.Weight) -> Int {
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

    var bodyFont: PlatformFont { font(size, weight: bodyWeight) }

    var codeFont: PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
    }

    var tableBodyFont: PlatformFont { Self.withMonospacedDigits(font(size * 0.90, weight: bodyWeight)) }

    var tableHeaderFont: PlatformFont { font(size * 0.90, weight: .semibold) }

    func headingWeight(level: Int) -> PlatformFont.Weight {
        [.bold, .semibold, .medium, .medium, .regular, .regular][min(level, 6) - 1]
    }

    /// Tabular (monospaced) figures so digits align vertically across table rows.
    private static func withMonospacedDigits(_ font: PlatformFont) -> PlatformFont {
        // The two feature keys are named differently per platform. CRUCIAL on iOS:
        // `UIFontDescriptor.FeatureKey.typeIdentifier` is a DEPRECATED ALIAS of
        // `.selector` (not the type key) — using it alongside `.selector` makes a
        // dictionary with two identical keys and crashes ("duplicate keys"). The
        // current, distinct iOS keys are `.type` and `.selector`.
        #if canImport(AppKit)
        let feature: [PlatformFontDescriptor.FeatureKey: Any] = [
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector
        ]
        #else
        let feature: [PlatformFontDescriptor.FeatureKey: Any] = [
            .type: kNumberSpacingType,
            .selector: kMonospacedNumbersSelector
        ]
        #endif
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [feature]])
        #if canImport(AppKit)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    func headingFont(level: Int) -> PlatformFont {
        let clamped = min(level, 6) - 1
        let scale: Double = [1.8, 1.5, 1.25, 1.125, 1.0, 1.0][clamped]
        return font(size * scale, weight: headingWeight(level: level))
    }

    /// Synthetic-bold stroke (negative `.strokeWidth` = fill+stroke in the text color)
    /// for families lacking a real heavier cut: when the resolved face is lighter than
    /// `target`, thicken strokes in proportion to the weight gap. Returns nil for the
    /// system font and whenever a real weight cut already covers the target — so 苹方
    /// and real-weight families (霞鹜文楷) are byte-for-byte unaffected.
    func synthStroke(of resolved: PlatformFont, target: PlatformFont.Weight) -> CGFloat? {
        guard fontFamily != nil else { return nil }
        #if canImport(AppKit)
        let deficit = Self.managerWeight(target) - NSFontManager.shared.weight(of: resolved)
        guard deficit > 0 else { return nil }
        return -CGFloat(deficit) * 1.1
        #else
        return nil
        #endif
    }

    // MARK: Colors

    var textColor: PlatformColor { .textColor }
    var linkColor: PlatformColor { .linkColor }
    var codeBackgroundColor: PlatformColor { .textColor.withAlphaComponent(0.035) }
    var quoteTextColor: PlatformColor { .secondaryLabelColor }
    var separatorTextColor: PlatformColor { .tertiaryLabelColor }
    var tableCornerRadius: CGFloat { 9 }
    var tableCardFillColor: PlatformColor { .textColor.withAlphaComponent(0.022) }
    var tableCardBorderColor: PlatformColor { .separatorColor }
    var tableHeaderFillColor: PlatformColor { .textColor.withAlphaComponent(0.04) }
    var tableRowSeparatorColor: PlatformColor { .textColor.withAlphaComponent(0.05) }
    var tableHeaderTextColor: PlatformColor { .secondaryLabelColor }
    var tableHeaderKern: CGFloat { CGFloat(size * 0.03) }

    func headingColor(level: Int) -> PlatformColor {
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

    // `var` so table-cell rendering can temporarily swap in a scratch buffer (iOS).
    var attributed = NSMutableAttributedString()
    let style: RenderStyle
    var headings: [HeadingAnchor] = []

    /// Current base font (body or heading — changed per block).
    var baseFont: PlatformFont
    /// Intended weight of the current block's base — what the design *asks for*, which
    /// may exceed what the chosen face actually provides (drives synthetic bold).
    var baseWeight: PlatformFont.Weight = .regular
    /// Inline font traits pushed/popped by Strong/Emphasis.
    var traits: PlatformFontDescriptor.SymbolicTraits = []
    /// Active paragraph style for the current block.
    var ps: NSParagraphStyle
    /// Active block text color, used for quotes and dim headings.
    var activeTextColor: PlatformColor?
    /// Active kerning (letter-spacing) for the current run; used for table headers.
    var activeKern: CGFloat?
    /// Active link URL (non-nil when inside a Link element).
    var linkURL: String?

    var currentFont: PlatformFont {
        guard !traits.isEmpty else { return baseFont }
        let combinedTraits = baseFont.fontDescriptor.symbolicTraits.union(traits)
        #if canImport(AppKit)
        let desc = baseFont.fontDescriptor.withSymbolicTraits(combinedTraits)
        return NSFont(descriptor: desc, size: baseFont.pointSize) ?? baseFont
        #elseif canImport(UIKit)
        guard let desc = baseFont.fontDescriptor.withSymbolicTraits(combinedTraits) else { return baseFont }
        return UIFont(descriptor: desc, size: baseFont.pointSize)
        #endif
    }

    /// Synthetic-bold stroke for the current run: the block's intended weight, bumped
    /// to bold when inside `**…**`. Nil unless the chosen face falls short of it.
    var currentStroke: CGFloat? {
        var target = baseWeight
        if traits.contains(.boldTrait),
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
        #if canImport(AppKit)
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
        #else
        // iOS: NSTextTable doesn't exist in UIKit. Embed the table as a native card
        // view via a TextKit 2 attachment — same path-D chrome as the Mac blocks.
        let headerCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows.map { Array($0.cells) })
        let bodyColumnCount = bodyRows.reduce(0) { max($0, $1.count) }
        let columnCount = max(headerCells.count, bodyColumnCount)
        guard columnCount > 0 else { return }

        let texts = tableCellTexts(headerCells: headerCells, bodyRows: bodyRows, columnCount: columnCount)
        let columnAlignments = table.columnAlignments
        let alignments = (0..<columnCount).map { column -> NSTextAlignment in
            if column < columnAlignments.count, let explicit = columnAlignments[column] {
                return textAlignment(for: explicit)
            }
            return TableLayoutMath.isNumericColumn(column, rowTexts: texts.rows) ? .right : .natural
        }

        let header = (0..<columnCount).map { column in
            renderedTableCell(column < headerCells.count ? headerCells[column] : nil,
                              isHeader: true, alignment: alignments[column])
        }
        let rows = bodyRows.map { rowCells in
            (0..<columnCount).map { column in
                renderedTableCell(column < rowCells.count ? rowCells[column] : nil,
                                  isHeader: false, alignment: alignments[column])
            }
        }
        let rendered = RenderedTable(headerCells: header, rows: rows,
                                     headerTexts: texts.header, rowTexts: texts.rows,
                                     headerFont: style.tableHeaderFont, bodyFont: style.tableBodyFont,
                                     cardFillColor: style.tableCardFillColor,
                                     cardBorderColor: style.tableCardBorderColor,
                                     headerFillColor: style.tableHeaderFillColor,
                                     rowSeparatorColor: style.tableRowSeparatorColor,
                                     cornerRadius: style.tableCornerRadius)

        ps = style.bodyParagraphStyle
        let attachmentString = NSMutableAttributedString(attachment: TableAttachment(table: rendered))
        attachmentString.addAttribute(.paragraphStyle, value: ps,
                                      range: NSRange(location: 0, length: attachmentString.length))
        attributed.append(attachmentString)
        newlines(1)
        #endif
    }

    #if canImport(UIKit)
    /// Render one cell's inlines into a standalone attributed string for the native
    /// table card — same font/color/kern state as the Mac's visitTableCell, captured
    /// by swapping in a scratch buffer so inline styling (bold, links, code) survives.
    private func renderedTableCell(_ cell: Markup?, isHeader: Bool, alignment: NSTextAlignment) -> NSAttributedString {
        let previousBuffer = attributed
        let previousBaseFont = baseFont
        let previousBaseWeight = baseWeight
        let previousTraits = traits
        let previousParagraphStyle = ps
        let previousTextColor = activeTextColor
        let previousKern = activeKern
        let previousLinkURL = linkURL

        attributed = NSMutableAttributedString()
        baseFont = isHeader ? style.tableHeaderFont : style.tableBodyFont
        baseWeight = isHeader ? .semibold : style.bodyWeight
        traits = []
        activeTextColor = isHeader ? style.tableHeaderTextColor : previousTextColor
        activeKern = isHeader ? style.tableHeaderKern : nil
        linkURL = nil
        let cellStyle = NSMutableParagraphStyle()
        cellStyle.alignment = alignment
        cellStyle.lineSpacing = style.tableLineSpacing
        cellStyle.lineBreakMode = .byWordWrapping
        ps = cellStyle

        if let cell {
            walkInlines(cell.children)
        }
        if attributed.length == 0 {
            append("—", color: .tertiaryLabelColor)
        }
        let result = attributed

        attributed = previousBuffer
        baseFont = previousBaseFont
        baseWeight = previousBaseWeight
        traits = previousTraits
        ps = previousParagraphStyle
        activeTextColor = previousTextColor
        activeKern = previousKern
        linkURL = previousLinkURL
        return result
    }
    #endif

    /// Per-cell plain texts (header row + body rows), padded to `columnCount` — the
    /// measurement input for `TableLayoutMath` on both platforms.
    private func tableCellTexts(headerCells: [Markup], bodyRows: [[Markup]], columnCount: Int) -> (header: [String], rows: [[String]]) {
        let header = (0..<columnCount).map { $0 < headerCells.count ? plainText(of: headerCells[$0]) : "" }
        let rows = bodyRows.map { rowCells in
            (0..<columnCount).map { $0 < rowCells.count ? plainText(of: rowCells[$0]) : "" }
        }
        return (header, rows)
    }

    #if canImport(AppKit)
    /// Column widths driven by real text measurement (mirrors Reading.measure = 700).
    private func tableColumnWidthPercentages(headerCells: [Markup], bodyRows: [[Markup]], columnCount: Int) -> [CGFloat] {
        let referenceContentWidth: CGFloat = 700
        let cellHorizontalPadding: CGFloat = 24
        let budget = max(referenceContentWidth - CGFloat(columnCount) * cellHorizontalPadding, 1)
        let texts = tableCellTexts(headerCells: headerCells, bodyRows: bodyRows, columnCount: columnCount)
        let widths = TableLayoutMath.columnWidths(headerTexts: texts.header, rowTexts: texts.rows,
                                                  headerFont: style.tableHeaderFont,
                                                  bodyFont: style.tableBodyFont,
                                                  budget: budget)
        return widths.map { $0 / budget * 100 }
    }

    /// A column reads as numeric when every non-empty body cell parses as a number,
    /// so it can be right-aligned even when the Markdown gave no alignment marker.
    private func isNumericColumn(_ column: Int, bodyRows: [[Markup]]) -> Bool {
        let rowTexts = bodyRows.map { rowCells in
            (0...column).map { $0 < rowCells.count ? plainText(of: rowCells[$0]) : "" }
        }
        return TableLayoutMath.isNumericColumn(column, rowTexts: rowTexts)
    }

    private func visitTableCell(_ cell: Markup?, card: RoundedCardBlock, table: NSTextTable, row: Int, column: Int, columnCount: Int, isHeader: Bool, isLastRow: Bool, columnWidthPercent: CGFloat, columnAlignment: Table.ColumnAlignment?) {
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
        baseWeight = previousBaseWeight
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

    #endif

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
            let color: PlatformColor = linkURL != nil ? style.linkColor : (activeTextColor ?? style.textColor)
            let start = attributed.length
            // Table headers carry an explicit uniform kern; elsewhere apply tracking
            // only to CJK glyphs (Latin reads well untouched — only 中文 packs tight).
            append(t.string, font: currentFont, color: color, link: linkURL,
                   kern: activeKern, stroke: currentStroke)
            if activeKern == nil, style.bodyKern > 0 {
                applyCJKKern(t.string, from: start, kern: style.bodyKern)
            }

        case let strong as Strong:
            traits.insert(.boldTrait)
            walkInlines(strong.children)
            traits.remove(.boldTrait)

        case let em as Emphasis:
            traits.insert(.italicTrait)
            walkInlines(em.children)
            traits.remove(.italicTrait)

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

    private func append(_ text: String, font: PlatformFont? = nil, color: PlatformColor? = nil,
                        bg: PlatformColor? = nil, link: String? = nil, kern: CGFloat? = nil,
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

// MARK: - Table column measurement

/// Column-width solver shared by the macOS NSTextTable path (700pt reference budget,
/// converted to percentages) and the iOS table card view (solved at the live view
/// width). Pure text measurement — no AppKit/UIKit layout types.
enum TableLayoutMath {
    /// Absolute column widths summing exactly to `budget`. Each column is given at
    /// least the width of its widest unbreakable token (so Latin words and short CJK
    /// headers never break mid-word), then the remaining budget is shared in
    /// proportion to each column's natural single-line width (capped at 45%); the
    /// result is normalized to fill `budget`.
    static func columnWidths(headerTexts: [String], rowTexts: [[String]],
                             headerFont: PlatformFont, bodyFont: PlatformFont,
                             budget: CGFloat) -> [CGFloat] {
        let columnCount = headerTexts.count
        guard columnCount > 0, budget > 0 else { return [] }
        let naturalCap = budget * 0.45

        var minWidths = [CGFloat](repeating: 0, count: columnCount)
        var naturalWidths = [CGFloat](repeating: 0, count: columnCount)

        for column in 0..<columnCount {
            let header = headerTexts[column]
            minWidths[column] = max(minWidths[column], longestUnbreakableWidth(header, font: headerFont))
            naturalWidths[column] = max(naturalWidths[column], singleLineWidth(header, font: headerFont))
            for row in rowTexts where column < row.count {
                let text = row[column]
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
        guard total > 0 else { return Array(repeating: budget / CGFloat(columnCount), count: columnCount) }
        return widths.map { $0 / total * budget }
    }

    /// Total text width (chrome excluded) the table needs: `natural` lays every cell
    /// on a single line; `min` is the narrowest width at which no unbreakable token
    /// splits. Drives the iOS card's scroll-vs-wrap decision.
    static func requiredTextWidths(headerTexts: [String], rowTexts: [[String]],
                                   headerFont: PlatformFont, bodyFont: PlatformFont) -> (min: CGFloat, natural: CGFloat) {
        var minTotal: CGFloat = 0
        var naturalTotal: CGFloat = 0
        for column in 0..<headerTexts.count {
            var minWidth = longestUnbreakableWidth(headerTexts[column], font: headerFont)
            var naturalWidth = singleLineWidth(headerTexts[column], font: headerFont)
            for row in rowTexts where column < row.count {
                minWidth = max(minWidth, longestUnbreakableWidth(row[column], font: bodyFont))
                naturalWidth = max(naturalWidth, singleLineWidth(row[column], font: bodyFont))
            }
            minTotal += minWidth
            naturalTotal += max(naturalWidth, minWidth)
        }
        return (minTotal, naturalTotal)
    }

    /// Width of `text` laid out on a single line.
    static func singleLineWidth(_ text: String, font: PlatformFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Width of the widest run the line-breaker won't split: whitespace and CJK
    /// boundaries allow breaks, so Latin words stay whole while CJK measures per char.
    static func longestUnbreakableWidth(_ text: String, font: PlatformFont) -> CGFloat {
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

    private static func isCJKBreakable(_ scalar: Unicode.Scalar) -> Bool {
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
    static func isNumericColumn(_ column: Int, rowTexts: [[String]]) -> Bool {
        var sawNumber = false
        for row in rowTexts where column < row.count {
            let text = row[column].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard isNumericToken(text) else { return false }
            sawNumber = true
        }
        return sawNumber
    }

    /// Lenient numeric test: tolerates currency, percent, thousands separators and
    /// accounting-style parentheses before checking the remainder parses as a Double.
    static func isNumericToken(_ raw: String) -> Bool {
        var token = raw
        if token.hasPrefix("(") && token.hasSuffix(")") {
            token = String(token.dropFirst().dropLast())
        }
        let decorations = Set("$€£¥%, ")
        token = String(token.filter { !decorations.contains($0) })
        guard !token.isEmpty else { return false }
        return Double(token) != nil
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
