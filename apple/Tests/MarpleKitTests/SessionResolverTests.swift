import Testing
import Foundation
@testable import MarpleKit

@Suite struct SessionResolverTests {
    private func mk(path: String) -> Entry {
        Entry(path: path, type: .note, title: nil, author: [],
              year: nil, ratingScore: 0, themes: [], topics: [],
              preview: "", hasPDF: false, book: nil, annotates: nil)
    }

    @Test func resolvesDocsAndPrunesUnknownPaths() {
        let e = mk(path: "vault/papers/p.md")
        let snap = SessionSnapshot(updatedAtMs: 1000, spaces: [
            SessionSpaceSnapshot(id: UUID(), name: "S", iconName: nil,
                roots: [.doc(OpenDocSnapshot(path: "vault/papers/p.md", title: "P", type: "paper")),
                        .doc(OpenDocSnapshot(path: "vault/gone.md", title: "X", type: "note"))],
                activePath: nil)])
        let spaces = SessionResolver.resolve(snap, entries: [e])
        #expect(spaces.count == 1)
        #expect(spaces[0].roots.count == 1)
        if case .doc(_, let entry, let label) = spaces[0].roots[0] {
            #expect(entry.path == e.path); #expect(label == "P")
        } else { Issue.record("expected a doc node") }
    }

    @Test func prunesEmptyGroupsAndSpaces() {
        let snap = SessionSnapshot(updatedAtMs: 1, spaces: [
            SessionSpaceSnapshot(id: UUID(), name: "S", iconName: nil,
                roots: [.group(name: "G", isCollapsed: false,
                               children: [.doc(OpenDocSnapshot(path: "vault/gone.md", title: "X", type: "note"))])],
                activePath: nil)])
        #expect(SessionResolver.resolve(snap, entries: []).isEmpty)
    }

    @Test func preservesGroupNestingIconActiveAndCollapse() {
        let e = mk(path: "vault/notes/n.md")
        let snap = SessionSnapshot(updatedAtMs: 1, spaces: [
            SessionSpaceSnapshot(id: UUID(), name: "S", iconName: "star",
                roots: [.group(name: "G", isCollapsed: true,
                               children: [.doc(OpenDocSnapshot(path: "vault/notes/n.md", title: "N", type: "note"))])],
                activePath: "vault/notes/n.md")])
        let spaces = SessionResolver.resolve(snap, entries: [e])
        #expect(spaces[0].iconName == "star")
        #expect(spaces[0].activePath == "vault/notes/n.md")
        if case .group(_, let name, let collapsed, let kids) = spaces[0].roots[0] {
            #expect(name == "G"); #expect(collapsed == true); #expect(kids.count == 1)
        } else { Issue.record("expected a group node") }
    }

    @Test func nodeIDsAreUnique() {
        let a = mk(path: "vault/a.md"); let b = mk(path: "vault/b.md")
        let snap = SessionSnapshot(updatedAtMs: 1, spaces: [
            SessionSpaceSnapshot(id: UUID(), name: "S", iconName: nil,
                roots: [.doc(OpenDocSnapshot(path: "vault/a.md", title: "A", type: "note")),
                        .doc(OpenDocSnapshot(path: "vault/b.md", title: "B", type: "note"))],
                activePath: nil)])
        let ids = SessionResolver.resolve(snap, entries: [a, b])[0].roots.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
