import Testing
@testable import MarpleKit

// MARK: - talk / transcript indexing (QUA-183)
//
// marple is a pure consumer of the Quasi `talk` / `transcript` schema contract
// (quasi 0.38.0 / schema 0.6.0). These tests pin the field mapping the indexer
// applies: speaker→author, date→created, and transcript title from the body
// heading (transcript frontmatter carries no `title`).

@Suite("TalkIndexing")
struct TalkIndexingTests {

    private func build(text: String, rel: String, fileStem: String) -> BuildOutcome {
        buildIndexedEntry(text: text, rel: rel, fileStem: fileStem, sourceSlugs: [], mtimeMs: nil)
    }

    @Test("canonicalType recognises talk and transcript")
    func canonical() {
        #expect(canonicalType("talk") == "talk")
        #expect(canonicalType("transcript") == "transcript")
    }

    @Test("talk: speaker→author, date→created, title from frontmatter")
    func talkFields() throws {
        let text = """
        ---
        type: talk
        title: Network Society
        date: 2024-11-08
        speaker:
          - Wang
          - Melina Lim
        themes:
          - network-society
          - platform-capitalism
        media: recording.mov
        ---

        # Network Society

        ## 核心论点

        本场会议聚焦全球南方的网络社会议题。

        ## 时间脉络

        - `[00:00]` 开幕致辞
        """
        let outcome = build(text: text,
                            rel: "vault/talks/network-society-20241108/talk.md",
                            fileStem: "talk")
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.entryType == "talk")
        #expect(entry.title == "Network Society")
        #expect(entry.author == ["Wang", "Melina Lim"])      // speaker → author
        #expect(entry.created == "2024-11-08")                // date → created
        #expect(entry.themes?.contains("network-society") == true)
    }

    @Test("talk: silent recording (no speaker) still indexes, author empty")
    func talkSilent() throws {
        let text = """
        ---
        type: talk
        title: Quiet Session
        date: 2024-10-02
        media: recording.mov
        ---

        # Quiet Session

        ## 核心论点

        （录制无有效音频，无法摘要）
        """
        let outcome = build(text: text,
                            rel: "vault/talks/quiet-session-20241002/talk.md",
                            fileStem: "talk")
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.entryType == "talk")
        #expect(entry.author.isEmpty)
        #expect(entry.created == "2024-10-02")
    }

    @Test("transcript: title from first body heading (no frontmatter title)")
    func transcriptTitle() throws {
        let text = """
        ---
        type: transcript
        talk: network-society-20241108
        ---

        # Network Society — 转写

        `[00:00]` events where technology, knowledge and culture are mixing.
        """
        let outcome = build(text: text,
                            rel: "vault/talks/network-society-20241108/transcript.md",
                            fileStem: "transcript")
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.entryType == "transcript")
        #expect(entry.title == "Network Society — 转写")
    }

    @Test("transcript: canonical frontmatter title wins over a differing body H1")
    func transcriptTitlePrefersFrontmatter() throws {
        let text = """
        ---
        type: transcript
        title: Network Society — Transcript
        talk: network-society-20241108
        ---

        # 自动转写草稿
        """
        let outcome = build(text: text,
                            rel: "vault/talks/network-society-20241108/transcript.md",
                            fileStem: "transcript")
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.title == "Network Society — Transcript")
    }

    @Test("conformance: talk `date` is verified (via created); `media` not false-flagged")
    func talkConformance() {
        let snap = SchemaSnapshot(requiredByType: ["talk": ["title", "date", "media"]])
        func talk(date: String?) -> Entry {
            Entry(path: "vault/talks/x/talk.md", type: .talk, title: "T", author: [],
                  year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false, created: date)
        }
        // title + date present; `media` is unmodeled → must not be reported missing.
        #expect(VaultConformance.check(talk(date: "2024-11-08"), against: snap)?.isConforming == true)
        // missing date → flagged via the created mapping (media still not flagged).
        #expect(VaultConformance.check(talk(date: nil), against: snap)?.missingRequired == ["date"])
    }
}
