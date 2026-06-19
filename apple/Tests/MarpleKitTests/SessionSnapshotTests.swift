import Foundation
import Testing
@testable import MarpleKit

@Suite struct SessionSnapshotTests {
    @Test func roundTripSpacesWithNestedForests() throws {
        let snap = SessionSnapshot(
            updatedAtMs: 1_700_000_000_000,
            spaces: [
                SessionSpaceSnapshot(
                    id: UUID(), name: "研究", iconName: "books.vertical",
                    roots: [
                        .doc(OpenDocSnapshot(path: "vault/papers/foo.md", title: "Foo", type: "paper")),
                        .group(name: "阅读中", isCollapsed: false, children: [
                            .doc(OpenDocSnapshot(path: "vault/notes/bar.md", title: "我的别名", type: "note")),
                            .group(name: "子组", isCollapsed: true, children: [
                                .doc(OpenDocSnapshot(path: "vault/papers/baz.md", title: "Baz", type: "paper")),
                            ]),
                        ]),
                    ],
                    activePath: "vault/papers/foo.md"),
                SessionSpaceSnapshot(
                    id: UUID(), name: "默认 Space", iconName: nil,
                    roots: [.doc(OpenDocSnapshot(path: "vault/books/qux.md", title: "Qux", type: "book"))],
                    activePath: nil),
            ])
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(back == snap)
        // Space name/icon + group name + custom label survive the round-trip.
        #expect(back.spaces[0].name == "研究")
        #expect(back.spaces[0].iconName == "books.vertical")
        #expect(back.spaces[1].iconName == nil)
        guard case .group(let name, _, let children) = back.spaces[0].roots[1] else {
            Issue.record("expected a group at spaces[0].roots[1]")
            return
        }
        #expect(name == "阅读中")
        guard case .doc(let leaf) = children[0] else {
            Issue.record("expected a doc leaf")
            return
        }
        #expect(leaf.title == "我的别名")
    }

    @Test func fileURLIsOutsideVaultAndMarple() {
        let url = SessionFile.url(workspaceRoot: "/tmp/ws")
        #expect(url.path == "/tmp/ws/session/open-tabs.json")
        #expect(!url.path.contains("/vault/"))
        #expect(!url.path.contains("/.marple/"))
    }
}
