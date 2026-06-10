#if canImport(UIKit)
import UIKit

// iOS table rendering: NSTextTable/NSTextTableBlock are macOS-only, so the Mac's
// path-D rounded-card chrome can't be drawn through text blocks here. Instead the
// renderer embeds one TextKit 2 attachment per table; its view provider supplies a
// TableCardView that draws the same chrome (card fill + border, whisper header band,
// faint row hairlines — the identical RenderStyle colors) and hosts the cell text,
// with column widths solved by the shared TableLayoutMath at the live view width.
//
// v3 (QUA-206): cells are live UITextViews (selectable, copyable, links tappable —
// per-cell only: the attachment is one character in the document, so selection can
// never span card and body text), and tables wider than the column lay out at the
// width they want — up to the Mac's 700pt measure — scrolling horizontally inside
// the card instead of wrapping into a ~360pt phone column.
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

/// The rounded table card: draws the card fill + border, and hosts the header band,
/// row hairlines and live cell text inside a horizontal scroll view. All chrome
/// metrics mirror the Mac's RoundedCardBlock/TableCellBlock so the two platforms
/// read identically.
public final class TableCardView: UIView {
    private let table: RenderedTable
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let headerBand = UIView()
    private var separators: [UIView] = []
    private var cellTextViews: [[UITextView]] = []   // header row first, then body rows

    // Mac block metrics: 2pt card padding, 14pt cell horizontal padding,
    // 14/18pt header vertical padding, 11pt body vertical padding.
    private static let cardInset: CGFloat = 2
    private static let cellPadH: CGFloat = 14
    private static let headerPadTop: CGFloat = 14
    private static let headerPadBottom: CGFloat = 18
    private static let bodyPadV: CGFloat = 11
    /// The Mac's reading measure — a wide table scrolls up to this layout width,
    /// beyond it the columns wrap exactly as they do on the Mac.
    private static let macMeasure: CGFloat = 700

    public init(table: RenderedTable) {
        self.table = table
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        // Fill/border colors resolve at draw time; redraw when light/dark flips.
        // (The band/hairline subviews carry dynamic colors and update themselves.)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: TableCardView, _) in
            self.setNeedsDisplay()
        }

        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.clipsToBounds = true
        scrollView.backgroundColor = .clear
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        headerBand.backgroundColor = table.headerFillColor
        contentView.addSubview(headerBand)
        // One hairline under the header (always, as on the Mac) and under each body
        // row except the last.
        for _ in 0..<(1 + max(table.rows.count - 1, 0)) {
            let line = UIView()
            line.backgroundColor = table.rowSeparatorColor
            contentView.addSubview(line)
            separators.append(line)
        }
        for cells in [table.headerCells] + table.rows {
            var rowViews: [UITextView] = []
            for cell in cells {
                let tv = UITextView()
                tv.isEditable = false
                tv.isSelectable = true
                tv.isScrollEnabled = false
                tv.backgroundColor = .clear
                tv.textContainerInset = .zero
                tv.textContainer.lineFragmentPadding = 0
                // Long-press must mean "select", not "drag": with text drag enabled
                // the lift-and-drag preview wins the gesture and selection never
                // starts. Dragging is useless in a read-only reader anyway.
                tv.textDragInteraction?.isEnabled = false
                tv.attributedText = cell
                contentView.addSubview(tv)
                rowViews.append(tv)
            }
            cellTextViews.append(rowViews)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("TableCardView does not support NSCoding")
    }

    // MARK: Layout

    private struct Layout {
        var contentWidth: CGFloat     // table layout width; > card width ⇒ scrolls
        var columnWidths: [CGFloat]   // text width per column (padding excluded)
        var rowHeights: [CGFloat]     // header first, then body rows
        var height: CGFloat
    }

    private static func layout(for table: RenderedTable, width: CGFloat) -> Layout {
        let columnCount = table.columnCount
        let chrome = 2 * cardInset + CGFloat(columnCount) * 2 * cellPadH
        // A table that wants more than the card width lays out at its natural
        // single-line width — capped at the Mac measure, but never below the width
        // of the widest unbreakable token — and scrolls horizontally.
        let required = TableLayoutMath.requiredTextWidths(headerTexts: table.headerTexts,
                                                          rowTexts: table.rowTexts,
                                                          headerFont: table.headerFont,
                                                          bodyFont: table.bodyFont)
        let contentWidth = max(width,
                               min(ceil(required.natural) + chrome, max(macMeasure, width)),
                               ceil(required.min) + chrome)
        let budget = max(contentWidth - chrome, CGFloat(columnCount))
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
        return Layout(contentWidth: contentWidth,
                      columnWidths: columnWidths,
                      rowHeights: rowHeights,
                      height: rowHeights.reduce(2 * cardInset, +))
    }

    /// Card height at `width` — used by the attachment to size itself before the
    /// view exists, with the same solver the view lays out from.
    public static func height(for table: RenderedTable, width: CGFloat) -> CGFloat {
        layout(for: table, width: width).height
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let layout = Self.layout(for: table, width: bounds.width)

        // Scroll viewport = card interior inside the 1pt border ring, rounded so the
        // header band and hairlines take their corners from the card and never bleed
        // past the border (was a draw-time clip in v2).
        scrollView.frame = bounds.insetBy(dx: 1, dy: 1)
        scrollView.layer.cornerRadius = max(table.cornerRadius - 1, 0)
        scrollView.contentSize = CGSize(width: layout.contentWidth - 2, height: bounds.height - 2)
        scrollView.isScrollEnabled = layout.contentWidth > bounds.width + 0.5
        contentView.frame = CGRect(x: 0, y: 0, width: layout.contentWidth - 2, height: bounds.height - 2)

        // Geometry below is solved in card coordinates; the viewport starts at (1,1).
        func place(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -1, dy: -1) }

        let headerBottom = Self.cardInset + layout.rowHeights[0]
        headerBand.frame = place(CGRect(x: 0, y: 0, width: layout.contentWidth, height: headerBottom))

        var separatorIndex = 0
        func placeSeparator(at y: CGFloat) {
            guard separatorIndex < separators.count else { return }
            separators[separatorIndex].frame = place(CGRect(x: 0, y: y - 1, width: layout.contentWidth, height: 1))
            separatorIndex += 1
        }
        var separatorY = headerBottom
        placeSeparator(at: separatorY)
        for rowIndex in 1..<max(layout.rowHeights.count - 1, 1) {
            separatorY += layout.rowHeights[rowIndex]
            placeSeparator(at: separatorY)
        }

        // Cell text: header top-aligned within its padding, body rows vertically
        // centered (the Mac cell blocks use .middleAlignment). Frames extend to the
        // row bottom so a hair of UITextView/boundingRect disagreement never clips.
        var rowTop = Self.cardInset
        for (rowIndex, rowViews) in cellTextViews.enumerated() {
            let isHeader = rowIndex == 0
            let rowHeight = layout.rowHeights[rowIndex]
            let cells = isHeader ? table.headerCells : table.rows[rowIndex - 1]
            var x = Self.cardInset
            for (column, tv) in rowViews.enumerated() {
                let textWidth = layout.columnWidths[column]
                let textHeight = ceil(cells[column].boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], context: nil).height)
                let y = isHeader ? rowTop + Self.headerPadTop
                                 : rowTop + (rowHeight - textHeight) / 2
                tv.frame = place(CGRect(x: x + Self.cellPadH, y: y,
                                        width: textWidth, height: rowTop + rowHeight - y))
                x += textWidth + 2 * Self.cellPadH
            }
            rowTop += rowHeight
        }
    }

    // MARK: Drawing

    public override func draw(_ rect: CGRect) {
        // Card surface + border (inset half a point so the 1px stroke is crisp).
        let cardRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let card = UIBezierPath(roundedRect: cardRect, cornerRadius: table.cornerRadius)
        table.cardFillColor.setFill()
        card.fill()
        card.lineWidth = 1
        table.cardBorderColor.setStroke()
        card.stroke()
    }
}

#endif
