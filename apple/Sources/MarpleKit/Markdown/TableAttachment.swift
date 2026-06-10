#if canImport(UIKit)
import UIKit

// iOS table rendering: NSTextTable/NSTextTableBlock are macOS-only, so the Mac's
// path-D rounded-card chrome can't be drawn through text blocks here. Instead the
// renderer embeds one TextKit 2 attachment per table; its view provider supplies a
// TableCardView that draws the same chrome (card fill + border, whisper header band,
// faint row hairlines — the identical RenderStyle colors) and the cell text, with
// column widths solved by the shared TableLayoutMath at the live view width.
//
// Requires the UITextView to be running TextKit 2 — touching `layoutManager`
// anywhere falls back to TextKit 1 and attachment views silently stop appearing.

/// Everything the table card needs to lay out and draw, captured at render time.
/// Cell content arrives pre-rendered (fonts, colors, alignment, inline styling baked
/// into the attributed strings); plain texts ride along for column measurement.
///
/// @unchecked Sendable: every stored value is immutable after init (the attributed
/// strings are defensively copied), and UIFont/UIColor are thread-safe — the struct
/// only crosses from the nonisolated TextKit 2 provider callbacks to the main actor.
public struct RenderedTable: @unchecked Sendable {
    public let headerCells: [NSAttributedString]
    public let rows: [[NSAttributedString]]
    let headerTexts: [String]
    let rowTexts: [[String]]
    let headerFont: UIFont
    let bodyFont: UIFont
    let cardFillColor: UIColor
    let cardBorderColor: UIColor
    let headerFillColor: UIColor
    let rowSeparatorColor: UIColor
    let cornerRadius: CGFloat

    init(headerCells: [NSAttributedString], rows: [[NSAttributedString]],
         headerTexts: [String], rowTexts: [[String]],
         headerFont: UIFont, bodyFont: UIFont,
         cardFillColor: UIColor, cardBorderColor: UIColor,
         headerFillColor: UIColor, rowSeparatorColor: UIColor, cornerRadius: CGFloat) {
        self.headerCells = headerCells.map { NSAttributedString(attributedString: $0) }
        self.rows = rows.map { $0.map { NSAttributedString(attributedString: $0) } }
        self.headerTexts = headerTexts
        self.rowTexts = rowTexts
        self.headerFont = headerFont
        self.bodyFont = bodyFont
        self.cardFillColor = cardFillColor
        self.cardBorderColor = cardBorderColor
        self.headerFillColor = headerFillColor
        self.rowSeparatorColor = rowSeparatorColor
        self.cornerRadius = cornerRadius
    }

    public var columnCount: Int { headerCells.count }
}

/// Attachment carrying a table through the rendered NSAttributedString.
public final class TableAttachment: NSTextAttachment {
    public let table: RenderedTable

    init(table: RenderedTable) {
        self.table = table
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TableAttachment does not support NSCoding")
    }

    public override func viewProvider(for parentView: UIView?, location: NSTextLocation,
                                      textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        TableAttachmentViewProvider(textAttachment: self, parentView: parentView,
                                    textLayoutManager: textContainer?.textLayoutManager,
                                    location: location)
    }
}

final class TableAttachmentViewProvider: NSTextAttachmentViewProvider {
    override init(textAttachment: NSTextAttachment, parentView: UIView?,
                  textLayoutManager: NSTextLayoutManager?, location: NSTextLocation) {
        super.init(textAttachment: textAttachment, parentView: parentView,
                   textLayoutManager: textLayoutManager, location: location)
        tracksTextAttachmentViewBounds = true
    }

    override func loadView() {
        guard let attachment = textAttachment as? TableAttachment else { return }
        view = TableCardView(table: attachment.table)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any],
                                   location: NSTextLocation, textContainer: NSTextContainer?,
                                   proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        guard let attachment = textAttachment as? TableAttachment else { return .zero }
        // The fragment spans the container width; text (and attachment origin) is
        // inset by the line-fragment padding, so the card width excludes both sides.
        let padding = textContainer?.lineFragmentPadding ?? 0
        let width = max(proposedLineFragment.width - 2 * padding, 1)
        let height = TableCardView.height(for: attachment.table, width: width)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
}

/// Draws the rounded table card and its cell text. All chrome metrics mirror the
/// Mac's RoundedCardBlock/TableCellBlock so the two platforms read identically.
public final class TableCardView: UIView {
    private let table: RenderedTable

    // Mac block metrics: 2pt card padding, 14pt cell horizontal padding,
    // 14/18pt header vertical padding, 11pt body vertical padding.
    private static let cardInset: CGFloat = 2
    private static let cellPadH: CGFloat = 14
    private static let headerPadTop: CGFloat = 14
    private static let headerPadBottom: CGFloat = 18
    private static let bodyPadV: CGFloat = 11

    public init(table: RenderedTable) {
        self.table = table
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        // Dynamic colors resolve at draw time; redraw when light/dark flips.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: TableCardView, _) in
            self.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("TableCardView does not support NSCoding")
    }

    // MARK: Layout

    private struct Layout {
        var columnWidths: [CGFloat]   // text width per column (padding excluded)
        var rowHeights: [CGFloat]     // header first, then body rows
        var height: CGFloat
    }

    private static func layout(for table: RenderedTable, width: CGFloat) -> Layout {
        let columnCount = table.columnCount
        let budget = max(width - 2 * cardInset - CGFloat(columnCount) * 2 * cellPadH, CGFloat(columnCount))
        let columnWidths = TableLayoutMath.columnWidths(headerTexts: table.headerTexts,
                                                        rowTexts: table.rowTexts,
                                                        headerFont: table.headerFont,
                                                        bodyFont: table.bodyFont,
                                                        budget: budget)

        func textHeight(_ cell: NSAttributedString, column: Int) -> CGFloat {
            ceil(cell.boundingRect(with: CGSize(width: columnWidths[column], height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin], context: nil).height)
        }
        var rowHeights: [CGFloat] = []
        let headerText = table.headerCells.enumerated().map { textHeight($1, column: $0) }.max() ?? 0
        rowHeights.append(headerText + headerPadTop + headerPadBottom)
        for row in table.rows {
            let text = row.enumerated().map { textHeight($1, column: $0) }.max() ?? 0
            rowHeights.append(text + 2 * bodyPadV)
        }
        return Layout(columnWidths: columnWidths,
                      rowHeights: rowHeights,
                      height: rowHeights.reduce(2 * cardInset, +))
    }

    /// Card height at `width` — used by the attachment to size itself before the
    /// view exists, with the same solver the view draws from.
    public static func height(for table: RenderedTable, width: CGFloat) -> CGFloat {
        layout(for: table, width: width).height
    }

    // MARK: Drawing

    public override func draw(_ rect: CGRect) {
        let layout = Self.layout(for: table, width: bounds.width)

        // Card surface + border (inset half a point so the 1px stroke is crisp).
        let cardRect = CGRect(x: 0, y: 0, width: bounds.width, height: layout.height)
            .insetBy(dx: 0.5, dy: 0.5)
        let card = UIBezierPath(roundedRect: cardRect, cornerRadius: table.cornerRadius)
        table.cardFillColor.setFill()
        card.fill()
        card.lineWidth = 1
        table.cardBorderColor.setStroke()
        card.stroke()

        // Header band + row hairlines, clipped to the card interior so they take
        // their rounded corners from the card and never bleed past the border.
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        UIBezierPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5),
                     cornerRadius: max(table.cornerRadius - 1, 0)).addClip()

        let headerBottom = Self.cardInset + layout.rowHeights[0]
        table.headerFillColor.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: headerBottom)).fill()

        // One hairline under the header (always, as on the Mac) and under each body
        // row except the last.
        func strokeSeparator(at y: CGFloat) {
            let line = UIBezierPath()
            line.move(to: CGPoint(x: 0, y: y - 0.5))
            line.addLine(to: CGPoint(x: bounds.width, y: y - 0.5))
            line.lineWidth = 1
            table.rowSeparatorColor.setStroke()
            line.stroke()
        }
        var separatorY = headerBottom
        strokeSeparator(at: separatorY)
        for rowIndex in 1..<max(layout.rowHeights.count - 1, 1) {
            separatorY += layout.rowHeights[rowIndex]
            strokeSeparator(at: separatorY)
        }
        ctx?.restoreGState()

        // Cell text: header top-aligned within its padding, body rows vertically
        // centered (the Mac cell blocks use .middleAlignment).
        var rowTop = Self.cardInset
        for (rowIndex, cells) in ([table.headerCells] + table.rows).enumerated() {
            let isHeader = rowIndex == 0
            let rowHeight = layout.rowHeights[rowIndex]
            var x = Self.cardInset
            for (column, cell) in cells.enumerated() {
                let textWidth = layout.columnWidths[column]
                let textHeight = ceil(cell.boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], context: nil).height)
                let y = isHeader ? rowTop + Self.headerPadTop
                                 : rowTop + (rowHeight - textHeight) / 2
                cell.draw(with: CGRect(x: x + Self.cellPadH, y: y, width: textWidth, height: textHeight),
                          options: [.usesLineFragmentOrigin], context: nil)
                x += textWidth + 2 * Self.cellPadH
            }
            rowTop += rowHeight
        }
    }
}

#endif
