import Testing
@testable import MarpleKit

@Suite struct DocStatsTests {
    @Test func cjkAndLatinWordCount() {
        // "技术物 X" → 3 CJK + 1 latin run = 4
        #expect(computeDocStats("技术物 X").words == 4)
    }
    @Test func latinRunIsOneWord() {
        #expect(countWords("hello world") == 2)
        #expect(countWords("foo123bar") == 1)   // one unbroken run
    }
    @Test func paragraphsSplitOnBlankLines() {
        #expect(computeDocStats("a\n\nb\n\n\nc").paragraphs == 3)
    }
    @Test func charsCountAndNoSpace() {
        let s = computeDocStats("a b\nc")
        #expect(s.chars == 5)
        #expect(s.charsNoSpace == 3)
    }
    @Test func minutesAtLeastOneWhenContent() {
        #expect(computeDocStats("hello world").minutes == 1)
        #expect(computeDocStats("").minutes == 0)
        #expect(computeDocStats("   \n  ").words == 0)
    }
    @Test func minutesRoundsByThreeHundred() {
        let body = String(repeating: "字", count: 600)
        #expect(computeDocStats(body).words == 600)
        #expect(computeDocStats(body).minutes == 2)
    }
}
