import XCTest
@testable import MarpleKit

final class SessionSnapshotTests: XCTestCase {
    func testRoundTrip() throws {
        let snap = SessionSnapshot(
            updatedAtMs: 1_700_000_000_000,
            openDocs: [
                OpenDocSnapshot(path: "vault/papers/foo.md", title: "Foo", type: "paper"),
                OpenDocSnapshot(path: "vault/notes/bar.md", title: "Bar", type: "note"),
            ],
            activePath: "vault/papers/foo.md")
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.openDocs.first?.id, "vault/papers/foo.md")
    }

    /// An unknown `type` raw value must not break decoding (forward-compat: a newer
    /// Mac could add an EntryType an older reader doesn't model). `type` is a String
    /// precisely so the reader maps it leniently instead of throwing.
    func testUnknownTypeStillDecodes() throws {
        let json = """
        {"version":1,"updatedAtMs":1,"openDocs":[{"path":"vault/x.md","title":"X","type":"hologram"}],"activePath":null}
        """.data(using: .utf8)!
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: json)
        XCTAssertEqual(back.openDocs.first?.type, "hologram")
    }

    func testFileURLIsOutsideVaultAndMarple() {
        let url = SessionFile.url(workspaceRoot: "/tmp/ws")
        XCTAssertEqual(url.path, "/tmp/ws/session/open-tabs.json")
        XCTAssertFalse(url.path.contains("/vault/"))
        XCTAssertFalse(url.path.contains("/.marple/"))
    }
}
