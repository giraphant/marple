import Testing
@testable import MarpleKit

@Suite("IndexBody")
struct IndexBodyTests {

    // MARK: - normalizeBodyForSearch

    @Test("normalizeBodyForSearch: CRLF→LF, trim each line, drop blank lines")
    func normalizeBasic() {
        #expect(normalizeBodyForSearch("a\r\n\n  b  \n\nc") == "a\nb\nc")
    }

    @Test("normalizeBodyForSearch: all blank lines → empty string")
    func normalizeAllBlank() {
        #expect(normalizeBodyForSearch("\n\n  \n\n") == "")
    }

    @Test("normalizeBodyForSearch: single line no changes needed")
    func normalizeSingleLine() {
        #expect(normalizeBodyForSearch("hello") == "hello")
    }

    @Test("normalizeBodyForSearch: CRLF only")
    func normalizeCRLFOnly() {
        #expect(normalizeBodyForSearch("a\r\nb") == "a\nb")
    }

    // MARK: - bodyLen

    @Test("bodyLen: CJK string counts unicode scalars (not grapheme clusters)")
    func bodyLenCJK() {
        // Each CJK character is one Unicode scalar
        let cjk = "中文测试"
        // normalizeBodyForSearch("中文测试") = "中文测试" (no changes)
        // .unicodeScalars.count = 4
        #expect(bodyLen(cjk) == 4)
    }

    @Test("bodyLen: ASCII string")
    func bodyLenASCII() {
        // normalizeBodyForSearch("hello") = "hello", 5 scalars
        #expect(bodyLen("hello") == 5)
    }

    @Test("bodyLen: CRLF normalized before counting")
    func bodyLenWithCRLF() {
        // "a\r\nb" → normalizeBodyForSearch → "a\nb" → 3 scalars
        #expect(bodyLen("a\r\nb") == 3)
    }

    @Test("bodyLen: blank lines dropped before counting")
    func bodyLenWithBlanks() {
        // "a\n\nb" → normalizeBodyForSearch → "a\nb" → 3 scalars
        #expect(bodyLen("a\n\nb") == 3)
    }

    // MARK: - searchText

    @Test("searchText: collapse internal whitespace, drop empty parts, join with newline")
    func searchTextBasic() {
        #expect(searchText(["a  b", "", "c"]) == "a b\nc")
    }

    @Test("searchText: single internal space unchanged")
    func searchTextSingleSpace() {
        // "a b" already has single space — stays "a b"
        #expect(searchText(["a b", "", "c"]) == "a b\nc")
    }

    @Test("searchText: all empty → empty string")
    func searchTextAllEmpty() {
        #expect(searchText(["", ""]) == "")
    }

    @Test("searchText: single non-empty part")
    func searchTextSinglePart() {
        #expect(searchText(["hello world"]) == "hello world")
    }

    @Test("searchText: tabs and multiple spaces collapsed")
    func searchTextMultiSpace() {
        #expect(searchText(["a\t\tb"]) == "a b")
    }

    // MARK: - firstHeading

    @Test("firstHeading: H2 in middle of body")
    func firstHeadingH2() {
        #expect(firstHeading("intro\n## Heading\n") == "Heading")
    }

    @Test("firstHeading: H1")
    func firstHeadingH1() {
        #expect(firstHeading("# Title\nsome text") == "Title")
    }

    @Test("firstHeading: H3")
    func firstHeadingH3() {
        #expect(firstHeading("### Deep\ntext") == "Deep")
    }

    @Test("firstHeading: no heading → nil")
    func firstHeadingNone() {
        #expect(firstHeading("just a paragraph") == nil)
    }

    @Test("firstHeading: heading without space after hashes → not a heading")
    func firstHeadingNoSpace() {
        // Rust requires whitespace after the hashes
        #expect(firstHeading("#NoSpace\ntext") == nil)
    }

    @Test("firstHeading: heading with empty text after trimming → skip")
    func firstHeadingEmptyText() {
        // "#   " trims to "" → skip; "## Real" follows
        #expect(firstHeading("#   \n## Real") == "Real")
    }

    @Test("firstHeading: first heading wins even if later headings exist")
    func firstHeadingFirst() {
        #expect(firstHeading("# First\n## Second") == "First")
    }

    // MARK: - isKVLabel

    @Test("isKVLabel: full-width colon form → true")
    func isKVLabelFullWidth() {
        #expect(isKVLabel("**作者**：张三") == true)
    }

    @Test("isKVLabel: ASCII colon form → true")
    func isKVLabelASCII() {
        #expect(isKVLabel("**Author**: X") == true)
    }

    @Test("isKVLabel: plain text → false")
    func isKVLabelPlain() {
        #expect(isKVLabel("plain") == false)
    }

    @Test("isKVLabel: starts with ** but no closing ** → false")
    func isKVLabelNoClose() {
        #expect(isKVLabel("**no close label: value") == false)
    }

    @Test("isKVLabel: ** wrapped but no colon after → false")
    func isKVLabelNoColon() {
        #expect(isKVLabel("**label** no colon here") == false)
    }

    @Test("isKVLabel: bold label with full-width colon and CJK value")
    func isKVLabelCJKValue() {
        #expect(isKVLabel("**英文原标题**：Some Title") == true)
    }

    // MARK: - firstParagraph

    @Test("firstParagraph: skip kv-label block, return first real paragraph")
    func firstParagraphSkipsKVLabel() {
        let body = """
        **作者**：张三
        **年份**：2020

        This is the real paragraph content.
        """
        let result = firstParagraph(body)
        #expect(result == "This is the real paragraph content.")
    }

    @Test("firstParagraph: headings-only doc → empty string")
    func firstParagraphHeadingsOnly() {
        let body = "# Heading One\n\n## Heading Two\n\n### Heading Three"
        #expect(firstParagraph(body) == "")
    }

    @Test("firstParagraph: skip leading --- paragraph")
    func firstParagraphSkipDashes() {
        let body = "---\nsome front matter\n\nReal content here."
        let result = firstParagraph(body)
        #expect(result == "Real content here.")
    }

    @Test("firstParagraph: skip single **...** block under 80 chars")
    func firstParagraphSkipBoldBlock() {
        let body = "**Short bold block**\n\nReal paragraph after."
        let result = firstParagraph(body)
        #expect(result == "Real paragraph after.")
    }

    @Test("firstParagraph: 800-scalar cap: long body truncated to 800")
    func firstParagraphCap() {
        // Create a body whose first real paragraph is well over 800 chars
        let longParagraph = String(repeating: "a", count: 1200)
        let result = firstParagraph(longParagraph)
        #expect(result.unicodeScalars.count <= 800)
    }

    @Test("firstParagraph: 800-scalar cap with CJK characters")
    func firstParagraphCapCJK() {
        // CJK chars: each is 1 unicode scalar but can be 3 bytes UTF-8
        let longParagraph = String(repeating: "中", count: 900)
        let result = firstParagraph(longParagraph)
        #expect(result.unicodeScalars.count <= 800)
    }

    @Test("firstParagraph: multiple paragraphs joined with space up to 800")
    func firstParagraphMultiple() {
        let body = "First paragraph.\n\nSecond paragraph."
        let result = firstParagraph(body)
        #expect(result == "First paragraph. Second paragraph.")
    }

    @Test("firstParagraph: CRLF normalized before processing")
    func firstParagraphCRLF() {
        let body = "First para.\r\n\r\nSecond para."
        let result = firstParagraph(body)
        #expect(result == "First para. Second para.")
    }

    @Test("firstParagraph: whitespace within paragraph collapsed")
    func firstParagraphWhitespaceCollapsed() {
        let body = "word1   word2\t\tword3"
        let result = firstParagraph(body)
        #expect(result == "word1 word2 word3")
    }

    @Test("firstParagraph: bold block >= 80 chars NOT skipped")
    func firstParagraphBoldLong() {
        // A paragraph starting and ending with ** but len >= 80 should NOT be skipped
        let inner = String(repeating: "x", count: 78) // "**" + 78x + "**" = 82 chars total, >= 80
        let body = "**\(inner)**"
        let result = firstParagraph(body)
        #expect(!result.isEmpty)
    }
}
