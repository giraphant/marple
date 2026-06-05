import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@Suite("TalkInspectorRows")
struct TalkInspectorRowsTests {

    private func talk(speaker: [String], date: String?) -> Entry {
        Entry(path: "vault/talks/network-society-20241108/talk.md",
              type: .talk, title: "Network Society", author: speaker, year: nil,
              ratingScore: 3, themes: [], preview: "", hasPDF: false, created: date)
    }

    private func transcript() -> Entry {
        Entry(path: "vault/talks/network-society-20241108/transcript.md",
              type: .transcript, title: "Network Society — 转写", author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }

    @Test("talk rows: authors row (讲者), 日期, transcript link, rating")
    func talkRows() {
        let entries = [talk(speaker: ["Wang"], date: "2024-11-08"), transcript()]
        #expect(inspectorInfoRows(for: entries[0], in: entries) == [
            .authors,
            .readOnlyScalar(label: "日期", value: "2024-11-08", copyValue: nil),
            .linkedScalar(label: "转写", value: "Network Society — 转写",
                          path: "vault/talks/network-society-20241108/transcript.md", copyValue: nil),
            .rating,
        ])
    }

    @Test("talk rows: silent talk still shows the authors row (add-讲者 affordance)")
    func talkSilent() {
        let entry = talk(speaker: [], date: "2024-10-02")
        #expect(inspectorInfoRows(for: entry, in: [entry]) == [
            .authors,
            .readOnlyScalar(label: "日期", value: "2024-10-02", copyValue: nil),
            .rating,
        ])
    }

    @Test("transcript rows: back-link to sibling talk")
    func transcriptRows() {
        let entries = [talk(speaker: ["Wang"], date: "2024-11-08"), transcript()]
        #expect(inspectorInfoRows(for: entries[1], in: entries) == [
            .linkedScalar(label: "讲座", value: "Network Society",
                          path: "vault/talks/network-society-20241108/talk.md", copyValue: nil),
        ])
    }

    @Test("SeekURL parses marple://seek/<seconds>; ignores wiki links")
    func seekURL() {
        #expect(SeekURL.seconds(from: URL(string: "marple://seek/3800")!) == 3800)
        #expect(SeekURL.seconds(from: URL(string: "marple://seek/0")!) == 0)
        #expect(SeekURL.seconds(from: URL(string: "marple://wiki/Network%20Society")!) == nil)
    }
}
