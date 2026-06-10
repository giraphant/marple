import XCTest
import UIKit
import MarpleKit

/// iOS table rendering: markdown tables become TextKit 2 `TableAttachment`s carrying
/// pre-rendered cells, hosted natively by `TableCardView` (QUA-201; live selectable
/// cells + horizontal scroll for wide tables in QUA-206).
@MainActor
final class TableRenderingTests: XCTestCase {
    private let style = RenderStyle(size: 17, fontFamily: nil, bodyWeight: .regular,
                                    letterSpacing: 0, lineHeight: 1.6)

    private func firstTableAttachment(in md: String) -> TableAttachment? {
        let doc = MarkdownRenderer.render(md, style: style)
        var found: TableAttachment?
        let full = NSRange(location: 0, length: doc.attributedString.length)
        doc.attributedString.enumerateAttribute(.attachment, in: full) { value, _, stop in
            if let attachment = value as? TableAttachment {
                found = attachment
                stop.pointee = true
            }
        }
        return found
    }

    func testTableBecomesAttachment() {
        let attachment = firstTableAttachment(in: "| A | B |\n|---|---|\n| 1 | 2 |\n| 你好 | 世界 |")
        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.table.columnCount, 2)
        XCTAssertEqual(attachment?.table.rows.count, 2)
    }

    func testNonTableContentHasNoAttachment() {
        XCTAssertNil(firstTableAttachment(in: "# 标题\n\n正文 with **bold**."))
    }

    func testNumericColumnRightAligned() {
        let attachment = firstTableAttachment(in: "| 名称 | 值 |\n|---|---|\n| a | 1.5 |\n| b | 2,000 |")
        let cell = attachment?.table.rows.first?[1]
        let ps = cell?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(ps?.alignment, .right)
    }

    func testExplicitAlignmentWins() {
        let attachment = firstTableAttachment(in: "| a | b |\n|:---:|---|\n| x | y |")
        let cell = attachment?.table.rows.first?[0]
        let ps = cell?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(ps?.alignment, .center)
    }

    func testRaggedRowsPadded() {
        let attachment = firstTableAttachment(in: "| A | B | C |\n|---|---|---|\n| only |")
        XCTAssertEqual(attachment?.table.columnCount, 3)
        XCTAssertEqual(attachment?.table.rows.first?.count, 3)
        // Empty cells render the same "—" placeholder as the Mac.
        XCTAssertEqual(attachment?.table.rows.first?[2].string, "—")
    }

    func testInlineStylingSurvivesInCells() {
        let attachment = firstTableAttachment(in: "| A |\n|---|\n| **bold** |")
        let cell = attachment?.table.rows.first?[0]
        let font = cell?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
    }

    func testCardHeightPositiveAndGrowsWithRows() {
        let one = firstTableAttachment(in: "| A | B |\n|---|---|\n| 1 | 2 |")!
        let two = firstTableAttachment(in: "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")!
        let h1 = TableCardView.height(for: one.table, width: 360)
        let h2 = TableCardView.height(for: two.table, width: 360)
        XCTAssertGreaterThan(h1, 0)
        XCTAssertGreaterThan(h2, h1)
    }

    /// End-to-end linchpin: a UITextView configured like MarkdownTextView must stay
    /// on TextKit 2 and actually materialize the attachment's TableCardView — a
    /// silent TextKit 1 fallback would make tables vanish without any other test
    /// failing.
    func testTableCardViewMaterializesInTextView() {
        let doc = MarkdownRenderer.render("before\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nafter",
                                          style: style)
        let tv = UITextView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        tv.isEditable = false
        tv.isSelectable = true
        tv.attributedText = doc.attributedString
        XCTAssertNotNil(tv.textLayoutManager, "UITextView fell back to TextKit 1")
        if let layoutManager = tv.textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        tv.layoutIfNeeded()

        func findCard(in view: UIView) -> TableCardView? {
            if let card = view as? TableCardView { return card }
            for sub in view.subviews {
                if let card = findCard(in: sub) { return card }
            }
            return nil
        }
        let card = findCard(in: tv)
        XCTAssertNotNil(card, "table attachment view was never materialized")
        XCTAssertGreaterThan(card?.bounds.width ?? 0, 100)
        XCTAssertGreaterThan(card?.bounds.height ?? 0, 0)
    }

    // MARK: v3 (QUA-206): live cell text + horizontal scroll

    private func materializedCard(in md: String, width: CGFloat) -> TableCardView {
        let attachment = firstTableAttachment(in: md)!
        let card = TableCardView(table: attachment.table)
        card.frame = CGRect(x: 0, y: 0, width: width,
                            height: TableCardView.height(for: attachment.table, width: width))
        card.layoutIfNeeded()
        return card
    }

    private func findViews<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        var found: [T] = []
        if let view = view as? T { found.append(view) }
        for sub in view.subviews { found.append(contentsOf: findViews(type, in: sub)) }
        return found
    }

    /// Cells are live UITextViews (selectable/copyable), not draw(_:)-painted text.
    func testCellTextIsLiveAndSelectable() {
        let card = materializedCard(in: "| A | B |\n|---|---|\n| hello | world |", width: 360)
        let cells = findViews(UITextView.self, in: card)
        XCTAssertEqual(cells.count, 4)
        for cell in cells {
            XCTAssertTrue(cell.isSelectable)
            XCTAssertFalse(cell.isEditable)
            XCTAssertFalse(cell.isScrollEnabled)
            // Text drag must stay off or its long-press lift beats selection.
            XCTAssertFalse(cell.textDragInteraction?.isEnabled ?? false)
        }
        let texts = Set(cells.map(\.text))
        XCTAssertTrue(texts.contains("hello"))
        XCTAssertTrue(texts.contains("world"))
    }

    /// v3: a table too wide for a phone column lays out at the width it wants and
    /// scrolls horizontally inside the card — so the card height no longer depends
    /// on the column width (in v2, narrow forced aggressive wrapping).
    func testNarrowWidthScrollsInsteadOfWrapping() {
        let md = "| 描述 |\n|---|\n| a fairly long sentence that must wrap on a narrow phone column |"
        let attachment = firstTableAttachment(in: md)!
        let wide = TableCardView.height(for: attachment.table, width: 700)
        let narrow = TableCardView.height(for: attachment.table, width: 200)
        XCTAssertEqual(narrow, wide)
    }

    func testWideTableScrollsHorizontally() {
        let md = """
        | first-column-header | second-column-header | third-column-header | fourth-column-header |
        |---|---|---|---|
        | unbreakable-identifier-one | unbreakable-identifier-two | unbreakable-identifier-three | unbreakable-identifier-four |
        """
        let card = materializedCard(in: md, width: 360)
        let scroll = findViews(UIScrollView.self, in: card).first
        XCTAssertNotNil(scroll)
        XCTAssertGreaterThan(scroll?.contentSize.width ?? 0, 360)
        XCTAssertTrue(scroll?.isScrollEnabled ?? false)
    }

    func testNarrowTableDoesNotScroll() {
        let card = materializedCard(in: "| A | B |\n|---|---|\n| 1 | 2 |", width: 360)
        let scroll = findViews(UIScrollView.self, in: card).first
        XCTAssertNotNil(scroll)
        XCTAssertLessThanOrEqual(scroll?.contentSize.width ?? .infinity, 360)
        XCTAssertFalse(scroll?.isScrollEnabled ?? true)
    }

    /// Breakable prose wider than the Mac's 700pt measure wraps there, as on the Mac,
    /// instead of producing an absurdly wide scroll.
    func testScrollWidthCappedAtMacMeasure() {
        let prose = "a very long breakable sentence that would naturally measure far past the mac reading measure all by itself"
        let md = "| 一 | 二 | 三 |\n|---|---|---|\n| \(prose) | \(prose) | \(prose) |"
        let card = materializedCard(in: md, width: 360)
        let scroll = findViews(UIScrollView.self, in: card).first
        XCTAssertGreaterThan(scroll?.contentSize.width ?? 0, 360)
        XCTAssertLessThanOrEqual(scroll?.contentSize.width ?? .infinity, 700)
    }
}
