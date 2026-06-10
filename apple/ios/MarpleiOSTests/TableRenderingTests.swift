import XCTest
import UIKit
import MarpleKit

/// iOS v2 table rendering: markdown tables become TextKit 2 `TableAttachment`s
/// carrying pre-rendered cells, drawn natively by `TableCardView` (QUA-201).
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

    func testCardHeightGrowsWhenNarrowWidthForcesWrapping() {
        let md = "| 描述 |\n|---|\n| a fairly long sentence that must wrap on a narrow phone column |"
        let attachment = firstTableAttachment(in: md)!
        let wide = TableCardView.height(for: attachment.table, width: 700)
        let narrow = TableCardView.height(for: attachment.table, width: 200)
        XCTAssertGreaterThan(narrow, wide)
    }
}
