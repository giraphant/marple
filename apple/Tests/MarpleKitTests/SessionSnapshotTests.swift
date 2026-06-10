import XCTest
@testable import MarpleKit

final class SessionSnapshotTests: XCTestCase {
    func testRoundTripNestedForest() throws {
        let snap = SessionSnapshot(
            updatedAtMs: 1_700_000_000_000,
            roots: [
                .doc(OpenDocSnapshot(path: "vault/papers/foo.md", title: "Foo", type: "paper")),
                .group(name: "阅读中", isCollapsed: false, children: [
                    .doc(OpenDocSnapshot(path: "vault/notes/bar.md", title: "我的别名", type: "note")),
                    .group(name: "子组", isCollapsed: true, children: [
                        .doc(OpenDocSnapshot(path: "vault/papers/baz.md", title: "Baz", type: "paper")),
                    ]),
                ]),
            ],
            activePath: "vault/papers/foo.md")
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        // Group name + custom label survive the round-trip.
        guard case .group(let name, _, let children) = back.roots[1] else {
            return XCTFail("expected a group at root[1]")
        }
        XCTAssertEqual(name, "阅读中")
        guard case .doc(let leaf) = children[0] else { return XCTFail("expected a doc leaf") }
        XCTAssertEqual(leaf.title, "我的别名")
    }

    func testFileURLIsOutsideVaultAndMarple() {
        let url = SessionFile.url(workspaceRoot: "/tmp/ws")
        XCTAssertEqual(url.path, "/tmp/ws/session/open-tabs.json")
        XCTAssertFalse(url.path.contains("/vault/"))
        XCTAssertFalse(url.path.contains("/.marple/"))
    }
}
