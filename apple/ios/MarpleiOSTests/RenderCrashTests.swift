import XCTest
import MarpleKit

/// Reproduces what DocScreen does when a document is opened, across markdown
/// features, to catch an iOS-only crash in the ported renderer.
final class RenderCrashTests: XCTestCase {
    private func renderDoc(_ md: String, file: StaticString = #filePath, line: UInt = #line) {
        let style = RenderStyle(size: 18, fontFamily: nil, bodyWeight: .regular,
                                letterSpacing: 0, lineHeight: 1.6)
        let pre = Wikilink.preprocessForRendering(md)
        let doc = MarkdownRenderer.render(pre, style: style)
        _ = doc.attributedString
        _ = MarpleKit.outline(from: doc.headings)
        _ = computeDocStats(md)
        XCTAssertGreaterThanOrEqual(doc.attributedString.length, 0, file: file, line: line)
    }

    func testHeadingsParagraphs() { renderDoc("# 标题\n\n正文 with **bold** *italic* `code`.\n\n## 二级\n更多内容") }
    func testTable() { renderDoc("| A | B |\n|---|---|\n| 1 | 2 |\n| 你好 | 世界 |\n| longer cell text | x |") }
    func testTableNumeric() { renderDoc("| 名称 | 值 |\n|---|---:|\n| a | 1.5 |\n| b | 2,000 |\n| c | (3) |") }
    func testLists() { renderDoc("- one\n- two\n  - nested\n\n1. first\n2. second") }
    func testCodeBlock() { renderDoc("```swift\nlet x = 1\nprint(x)\n```") }
    func testQuote() { renderDoc("> quote\n>\n> > nested quote") }
    func testLinks() { renderDoc("[link](https://example.com) and [[wikilink target]] inline") }
    func testThematicBreak() { renderDoc("a\n\n---\n\nb") }
    func testFrontmatterDoc() { renderDoc("---\ntype: paper\ntitle: T\nauthor: [X]\n---\n# Body\n\ntext with 表格:\n\n| h1 | h2 |\n|---|---|\n| 甲 | 乙 |") }
    func testImage() { renderDoc("![alt text](image.png) inline ![](no-alt.png)") }
    func testEmptyAndWhitespace() { renderDoc(""); renderDoc("   \n\n  ") }
}
