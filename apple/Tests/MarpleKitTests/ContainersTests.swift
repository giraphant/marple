import Testing
@testable import MarpleKit

@Suite struct ContainersTests {

    func mk(path: String, type: EntryType, kind: String? = nil) -> Entry {
        Entry(path: path, type: type, title: nil, author: [],
              year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false,
              kind: kind)
    }

    // talk/transcript 并入规则②容器：talk=overview，transcript=成员，双向可达。
    @Test func containerContextTalkPairsTalkAndTranscript() {
        let talk = mk(path: "vault/talks/t/talk.md", type: .talk)
        let transcript = mk(path: "vault/talks/t/transcript.md", type: .transcript)
        let entries = [transcript, talk]
        let fromTalk = containerContext(for: talk, in: entries)
        #expect(fromTalk?.overview?.path == talk.path)
        #expect(fromTalk?.children.map(\.path) == [transcript.path])
        let fromTranscript = containerContext(for: transcript, in: entries)
        #expect(fromTranscript?.overview?.path == talk.path)
        #expect(fromTranscript?.children.map(\.path) == [transcript.path])
    }

    // 无 transcript 的 talk：仍是有效容器（overview 在、成员空），同空书可见。
    @Test func containerContextTalkWithoutTranscript() {
        let talk = mk(path: "vault/talks/t/talk.md", type: .talk)
        let c = containerContext(for: talk, in: [talk])
        #expect(c?.overview?.path == talk.path)
        #expect(c?.children.isEmpty == true)
    }

    @Test func containerContextBookMatchesBookContext() {
        let overview = mk(path: "vault/books/b/00-overview.md", type: .book)
        let c1 = mk(path: "vault/books/b/01-x.md", type: .chapter)
        let entries = [c1, overview]
        let via = containerContext(for: c1, in: entries)
        #expect(via?.overview?.path == overview.path)
        #expect(via?.children.map(\.path) == [c1.path])
        #expect(bookContext(for: c1, in: entries)?.chapters.map(\.path) == via?.children.map(\.path))
    }

    @Test func containerContextTopicMatchesTopicContext() {
        let ov = mk(path: "vault/topics/t/00-overview.md", type: .topic, kind: "overview")
        let res = mk(path: "vault/topics/t/01-resources.md", type: .topic)
        let entries = [res, ov]
        let via = containerContext(for: res, in: entries)
        #expect(via?.overview?.path == ov.path)
        #expect(via?.children.map(\.path) == [res.path])
        #expect(topicContext(for: res, in: entries)?.pages.map(\.path) == via?.children.map(\.path))
    }

    @Test func containerContextNilForNonContainerTypes() {
        let paper = mk(path: "vault/papers/p.md", type: .paper)
        #expect(containerContext(for: paper, in: [paper]) == nil)
    }
}
