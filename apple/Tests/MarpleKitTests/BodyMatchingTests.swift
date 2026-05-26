import Testing
import Foundation
@testable import MarpleKit

private extension NSString {
    func sub(_ r: NSRange) -> String { substring(with: r) }
}

@Suite struct BodyMatchingTests {
    @Test func termsSplitOnWhitespaceDropEmpties() {
        #expect(BodyMatching.terms(from: "  汽车   维修 ") == ["汽车", "维修"])
        #expect(BodyMatching.terms(from: "") == [])
        #expect(BodyMatching.terms(from: "   ") == [])
        #expect(BodyMatching.terms(from: "single") == ["single"])
    }

    @Test func findsAllOccurrencesOrdered() {
        let text = "所以这样，所以那样，所以结束"
        let r = BodyMatching.ranges(in: text, query: "所以")
        #expect(r.count == 3)
        let ns = text as NSString
        for range in r { #expect(ns.sub(range) == "所以") }
        // ordered by location
        #expect(r.map(\.location) == r.map(\.location).sorted())
    }

    @Test func caseAndDiacriticInsensitive() {
        let text = "Café au lait, CAFE noir, cafe latte"
        let r = BodyMatching.ranges(in: text, query: "cafe")
        #expect(r.count == 3)
    }

    @Test func multipleTermsAnyMatch() {
        let text = "汽车很好，维修很贵，天气不错"
        let r = BodyMatching.ranges(in: text, terms: ["汽车", "维修"])
        #expect(r.count == 2)
    }

    @Test func overlappingSameSpanMerges() {
        // Two terms hitting the same span collapse to one range.
        let text = "café"
        let r = BodyMatching.ranges(in: text, terms: ["café", "cafe"])
        #expect(r.count == 1)
    }

    @Test func overlappingTermsMerge() {
        let r = BodyMatching.ranges(in: "abc", terms: ["ab", "bc"])
        #expect(r == [NSRange(location: 0, length: 3)])
    }

    @Test func adjacentDistinctTermsStaySeparate() {
        // "所" then "以" touch but do not overlap.
        let r = BodyMatching.ranges(in: "所以", terms: ["所", "以"])
        #expect(r.count == 2)
    }

    @Test func emptyInputs() {
        #expect(BodyMatching.ranges(in: "", query: "x").isEmpty)
        #expect(BodyMatching.ranges(in: "text", query: "").isEmpty)
        #expect(BodyMatching.ranges(in: "text", query: "zzz").isEmpty)
    }

    // MARK: resolveJumpTarget

    @Test func resolveJumpNoMatchesIsNil() {
        #expect(BodyMatching.resolveJumpTarget(in: "abc", matchRanges: [], anchor: "a", ordinal: 0) == nil)
    }

    @Test func resolveJumpDuplicateLinesPicksOrdinalOccurrence() {
        // Two identical matched lines; the anchor's first occurrence would be wrong
        // for the 2nd line — ordinal must disambiguate.
        let text = "X 所以 Y\n中间无关\nX 所以 Y"
        let ranges = BodyMatching.ranges(in: text, query: "所以")
        #expect(ranges.count == 2)
        let second = BodyMatching.resolveJumpTarget(in: text, matchRanges: ranges,
                                                    anchor: "X 所以 Y", ordinal: 1)
        #expect(second == ranges[1])   // not ranges[0]
        let first = BodyMatching.resolveJumpTarget(in: text, matchRanges: ranges,
                                                   anchor: "X 所以 Y", ordinal: 0)
        #expect(first == ranges[0])
    }

    @Test func resolveJumpAnchorMissingFallsBackToOrdinal() {
        let text = "只有一行所以这里"
        let ranges = BodyMatching.ranges(in: text, query: "所以")
        let t = BodyMatching.resolveJumpTarget(in: text, matchRanges: ranges,
                                               anchor: "不存在的锚", ordinal: 0)
        #expect(t == ranges[0])
    }

    @Test func resolveJumpAnchorCorrectsDriftedOrdinal() {
        // Ordinal points at the wrong occurrence (drift); the anchor line only
        // contains the 2nd match, so the anchor's inner match wins.
        let text = "首行所以一\n次行所以二"
        let ranges = BodyMatching.ranges(in: text, query: "所以")
        // anchor is the 2nd line but a (drifted) ordinal of 0 points at the 1st match.
        let t = BodyMatching.resolveJumpTarget(in: text, matchRanges: ranges,
                                               anchor: "次行所以二", ordinal: 0)
        #expect(t == ranges[1])   // anchor corrects the drift
    }
}

@Suite struct BodyLineMatchesTests {
    /// Verify each span actually points at a query term inside the excerpt.
    private func assertSpansMatch(_ line: BodyMatchLine, term: String) {
        let ns = line.excerpt as NSString
        for s in line.spans {
            let got = ns.substring(with: NSRange(location: s.location, length: s.length))
            #expect(got.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                    "span '\(got)' should contain '\(term)' in excerpt '\(line.excerpt)'")
        }
    }

    @Test func emptyQueryOrNoMatch() {
        #expect(bodyLineMatches(body: "hello world", query: "") == .empty)
        #expect(bodyLineMatches(body: "hello world", query: "zzz") == .empty)
        #expect(bodyLineMatches(body: "", query: "x") == .empty)
    }

    @Test func singleLineSingleMatch() {
        let m = bodyLineMatches(body: "螺丝刀和螺丝的共同演化", query: "螺丝")
        #expect(m.totalMatches == 2)
        #expect(m.lines.count == 1)
        let line = m.lines[0]
        #expect(line.lineIndex == 0)
        #expect(line.matchOrdinal == 0)
        #expect(line.spans.count == 2)
        assertSpansMatch(line, term: "螺丝")
    }

    @Test func multipleLinesOrdinalsIncrement() {
        let body = """
        第一行有所以一次
        无关行
        第二段所以再所以两次
        """
        let m = bodyLineMatches(body: body, query: "所以")
        #expect(m.lines.count == 2)
        #expect(m.totalMatches == 3)
        #expect(m.lines[0].lineIndex == 0)
        #expect(m.lines[0].matchOrdinal == 0)
        // second matched line is physical line index 2 (the "无关行" is line 1)
        #expect(m.lines[1].lineIndex == 2)
        #expect(m.lines[1].matchOrdinal == 1)  // its first match is the 2nd overall (0-based 1)
    }

    @Test func headingMarkerStripped() {
        let m = bodyLineMatches(body: "## 论争结构与所以", query: "所以")
        #expect(m.lines.count == 1)
        let line = m.lines[0]
        #expect(line.excerpt.hasPrefix("论争"))   // "## " gone
        assertSpansMatch(line, term: "所以")
    }

    @Test func listAndQuoteMarkersStripped() {
        let bullet = bodyLineMatches(body: "- 适应过程所以重要", query: "所以").lines[0]
        #expect(bullet.excerpt.hasPrefix("适应"))
        assertSpansMatch(bullet, term: "所以")

        let quote = bodyLineMatches(body: "> 引用里所以也算", query: "所以").lines[0]
        #expect(quote.excerpt.hasPrefix("引用"))
        assertSpansMatch(quote, term: "所以")

        let ordered = bodyLineMatches(body: "12. 列表项所以编号", query: "所以").lines[0]
        #expect(ordered.excerpt.hasPrefix("列表项"))
        assertSpansMatch(ordered, term: "所以")
    }

    @Test func hashtagNotStrippedWhenNoSpace() {
        // "#tag" (no following space) is not a heading marker; keep it.
        let m = bodyLineMatches(body: "#标签所以保留", query: "所以")
        #expect(m.lines[0].excerpt.hasPrefix("#标签"))
        assertSpansMatch(m.lines[0], term: "所以")
    }

    @Test func longLineWindowsAroundFirstMatchWithEllipsis() {
        let body = String(repeating: "前", count: 40) + "关键" + String(repeating: "后", count: 40)
        let m = bodyLineMatches(body: body, query: "关键", leadContext: 8, maxExcerpt: 30)
        let line = m.lines[0]
        #expect(line.excerpt.hasPrefix("…"))        // cut at the front
        #expect(line.excerpt.hasSuffix("…"))        // and the back
        #expect(line.excerpt.contains("关键"))
        assertSpansMatch(line, term: "关键")
    }

    @Test func multipleMatchesSameLine() {
        let line = bodyLineMatches(body: "所以又所以再所以", query: "所以").lines[0]
        #expect(line.spans.count == 3)
        assertSpansMatch(line, term: "所以")
    }

    @Test func stripLeadingMarkerHelper() {
        #expect(stripLeadingMarker("## Heading").cleaned == "Heading")
        #expect(stripLeadingMarker("- item").cleaned == "item")
        #expect(stripLeadingMarker("> quote").cleaned == "quote")
        #expect(stripLeadingMarker("3. ordered").cleaned == "ordered")
        #expect(stripLeadingMarker("#tag").cleaned == "#tag")        // no space → kept
        #expect(stripLeadingMarker("plain text").cleaned == "plain text")
        #expect(stripLeadingMarker("  indented  ").cleaned == "indented")
    }

    @Test func anchorIsFullPlainLine() {
        let line = bodyLineMatches(body: "## 论争结构与所以的关系", query: "所以").lines[0]
        #expect(line.anchor == "论争结构与所以的关系")   // full line, not windowed
    }

    @Test func wikilinkResolvesToLabelInExcerptAndAnchor() {
        let line = bodyLineMatches(body: "讨论[[技术物演化|技术]]时所以重要", query: "所以").lines[0]
        #expect(line.anchor == "讨论技术时所以重要")
        assertSpansMatch(line, term: "所以")
    }

    @Test func hiddenWikilinkTargetDoesNotInflateOrdinal() {
        // The query term lives in a wikilink TARGET that is not shown (label differs):
        // it must NOT count as a match, so the ordinal stays aligned with rendered text.
        let m = bodyLineMatches(body: "见[[所以的源头|源头]]，所以结束", query: "所以")
        #expect(m.totalMatches == 1)              // only the literal 所以, not the hidden target
        #expect(m.lines.count == 1)
        #expect(m.lines[0].matchOrdinal == 0)
    }

    @Test func emphasisMarkersStrippedFromExcerpt() {
        let line = bodyLineMatches(body: "**重点**：所以**很**关键", query: "所以").lines[0]
        #expect(!line.excerpt.contains("*"))
        assertSpansMatch(line, term: "所以")
    }
}

@Suite struct MarkdownLineTests {
    @Test func wikilinkToLabel() {
        #expect(MarkdownLine.plainText("看[[目标|标签]]结束") == "看标签结束")
        #expect(MarkdownLine.plainText("看[[概念]]结束") == "看概念结束")
    }
    @Test func leadingMarkersDropped() {
        #expect(MarkdownLine.plainText("### 标题") == "标题")
        #expect(MarkdownLine.plainText("- 列表项") == "列表项")
        #expect(MarkdownLine.plainText("> 引用") == "引用")
    }
    @Test func linksAndImages() {
        #expect(MarkdownLine.plainText("见[文字](http://x)处") == "见文字处")
        #expect(MarkdownLine.plainText("![描述](http://img)") == "描述")
    }
    @Test func inlineMarkers() {
        #expect(MarkdownLine.plainText("**粗** *斜* `码` ~~删~~") == "粗 斜 码 删")
    }
    @Test func plainStaysPlain() {
        #expect(MarkdownLine.plainText("普通中文段落") == "普通中文段落")
    }
}
