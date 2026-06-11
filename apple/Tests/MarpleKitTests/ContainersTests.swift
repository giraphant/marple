import Testing
@testable import MarpleKit

@Suite struct ContainersTests {

    func mk(path: String, type: EntryType, kind: String? = nil) -> Entry {
        Entry(path: path, type: type, title: nil, author: [],
              year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false,
              kind: kind)
    }

    @Test func siblingEntryResolvesWithinDirectory() {
        let talk = mk(path: "vault/talks/t/talk.md", type: .talk)
        let transcript = mk(path: "vault/talks/t/transcript.md", type: .transcript)
        #expect(siblingEntry(of: talk, named: "transcript.md", in: [talk, transcript])?.path == transcript.path)
        #expect(siblingEntry(of: transcript, named: "talk.md", in: [talk, transcript])?.path == talk.path)
    }

    @Test func siblingEntryNilWhenMissing() {
        let talk = mk(path: "vault/talks/t/talk.md", type: .talk)
        #expect(siblingEntry(of: talk, named: "transcript.md", in: [talk]) == nil)
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
