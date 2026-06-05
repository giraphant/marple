import Testing
@testable import MarpleKit

@Suite("TalkMedia")
struct TalkMediaTests {

    @Test("media filename picks recording.<ext>, excluding srt/md")
    func mediaPick() {
        let names = ["talk.md", "transcript.md", "recording.mov", "recording.srt"]
        #expect(TalkMedia.mediaFilename(among: names) == "recording.mov")
    }

    @Test("media filename: other extensions accepted")
    func mediaOtherExt() {
        #expect(TalkMedia.mediaFilename(among: ["recording.mp4"]) == "recording.mp4")
        #expect(TalkMedia.mediaFilename(among: ["recording.m4a"]) == "recording.m4a")
    }

    @Test("media filename: nil when recording absent (gitignored / fresh clone)")
    func mediaAbsent() {
        #expect(TalkMedia.mediaFilename(among: ["talk.md", "transcript.md", "recording.srt"]) == nil)
    }

    @Test("subtitles filename resolves recording.srt")
    func subtitles() {
        #expect(TalkMedia.subtitlesFilename(among: ["recording.mov", "recording.srt"]) == "recording.srt")
        #expect(TalkMedia.subtitlesFilename(among: ["recording.mov"]) == nil)
    }

    // MARK: - SRT

    private let srt = """
    1
    00:00:00,000 --> 00:00:02,500
    Hello world

    2
    00:00:02,500 --> 00:00:05,000
    second line
    wrapped
    """

    @Test("SRT.parse: two cues with correct timing and text")
    func parse() {
        let cues = SRT.parse(srt)
        #expect(cues.count == 2)
        #expect(cues[0] == SRTCue(start: 0, end: 2.5, text: "Hello world"))
        #expect(cues[1].start == 2.5)
        #expect(cues[1].end == 5)
        #expect(cues[1].text == "second line\nwrapped")
    }

    @Test("SRT.cue(at:): active cue, and nil outside windows")
    func cueAt() {
        let cues = SRT.parse(srt)
        #expect(SRT.cue(at: 1.0, in: cues) == "Hello world")
        #expect(SRT.cue(at: 2.5, in: cues) == "second line\nwrapped")
        #expect(SRT.cue(at: 9.0, in: cues) == nil)
    }

    @Test("SRT.parse: tolerates CRLF and missing index lines")
    func tolerant() {
        let messy = "00:00:01,000 --> 00:00:02,000\r\nno index here\r\n"
        let cues = SRT.parse(messy)
        #expect(cues.count == 1)
        #expect(cues[0].text == "no index here")
    }
}
