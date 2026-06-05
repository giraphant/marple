import Testing
@testable import MarpleKit

@Suite("TalkTimeline")
struct TalkTimelineTests {

    // MARK: - seconds(fromTimestamp:)

    @Test("mm:ss → seconds")
    func mmss() {
        #expect(TalkTimeline.seconds(fromTimestamp: "[00:00]") == 0)
        #expect(TalkTimeline.seconds(fromTimestamp: "[02:58]") == 178)
        #expect(TalkTimeline.seconds(fromTimestamp: "[26:08]") == 1568)
    }

    @Test("hh:mm:ss → seconds")
    func hhmmss() {
        #expect(TalkTimeline.seconds(fromTimestamp: "[01:03:20]") == 3800)
        #expect(TalkTimeline.seconds(fromTimestamp: "[02:58:17]") == 10697)
    }

    @Test("brackets optional")
    func noBrackets() {
        #expect(TalkTimeline.seconds(fromTimestamp: "01:03:20") == 3800)
    }

    @Test("out-of-range trailing field → nil")
    func outOfRange() {
        #expect(TalkTimeline.seconds(fromTimestamp: "[99:99]") == nil)
        #expect(TalkTimeline.seconds(fromTimestamp: "[01:75]") == nil)
    }

    @Test("non-timestamp → nil")
    func garbage() {
        #expect(TalkTimeline.seconds(fromTimestamp: "garbage") == nil)
        #expect(TalkTimeline.seconds(fromTimestamp: "[12]") == nil)
        #expect(TalkTimeline.seconds(fromTimestamp: "[1:2:3:4]") == nil)
    }

    // MARK: - linkifyTimestamps

    @Test("backtick mm:ss timestamp → seek link")
    func linkifyMMSS() {
        let out = TalkTimeline.linkifyTimestamps("- `[00:00]` 开幕致辞")
        #expect(out == "- [\\[00:00\\]](marple://seek/0) 开幕致辞")
    }

    @Test("backtick hh:mm:ss timestamp → seek link with seconds")
    func linkifyHHMMSS() {
        let out = TalkTimeline.linkifyTimestamps("- `[01:03:20]` 历史意义")
        #expect(out == "- [\\[01:03:20\\]](marple://seek/3800) 历史意义")
    }

    @Test("multiple timestamps on multiple lines all linkified")
    func linkifyMany() {
        let body = """
        - `[00:00]` a
        - `[04:05]` b
        """
        let out = TalkTimeline.linkifyTimestamps(body)
        #expect(out.contains("marple://seek/0"))
        #expect(out.contains("marple://seek/245"))
    }

    @Test("position-independent: same result whether timeline is 2nd or last")
    func positionIndependent() {
        // The 时间脉络 H2 sits 2nd in older talks and last in newer ones; the
        // timestamp tokens linkify identically regardless of section order.
        let early = "## 时间脉络\n- `[02:58]` x\n## 文献人物\n- y"
        let late  = "## 文献人物\n- y\n## 时间脉络\n- `[02:58]` x"
        #expect(TalkTimeline.linkifyTimestamps(early).contains("marple://seek/178"))
        #expect(TalkTimeline.linkifyTimestamps(late).contains("marple://seek/178"))
    }

    @Test("plain (non-backtick) timestamp left untouched")
    func plainUntouched() {
        let body = "日期 [00:00] not in backticks"
        #expect(TalkTimeline.linkifyTimestamps(body) == body)
    }

    @Test("no timestamps → unchanged")
    func noop() {
        let body = "## 核心论点\n散文一段，无时间戳。"
        #expect(TalkTimeline.linkifyTimestamps(body) == body)
    }
}
