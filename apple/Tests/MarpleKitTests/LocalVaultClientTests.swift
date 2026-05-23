import Testing
import Foundation
@testable import MarpleKit

@Suite struct LocalVaultClientTests {
    /// A temp workspace with a vault/ dir and an empty index path.
    private func makeWorkspace() throws -> (root: String, client: LocalVaultClient) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("vault/papers"), withIntermediateDirectories: true)
        let index = IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path)
        return (root.path, LocalVaultClient(workspaceRoot: root.path, index: index))
    }

    @Test func entryTextReadsFileRelativeToWorkspace() async throws {
        let (root, client) = try makeWorkspace()
        let abs = URL(fileURLWithPath: root).appendingPathComponent("vault/papers/a.md")
        try "# Hello".write(to: abs, atomically: true, encoding: .utf8)
        let text = try await client.entryText(path: "vault/papers/a.md")
        #expect(text == "# Hello")
    }

    @Test func entryTextMissingThrowsNotFound() async throws {
        let (_, client) = try makeWorkspace()
        await #expect(throws: VaultError.notFound("vault/papers/nope.md")) {
            _ = try await client.entryText(path: "vault/papers/nope.md")
        }
    }

    @Test func writeFileWritesToDisk() async throws {
        let (root, client) = try makeWorkspace()
        try await client.writeFile(path: "vault/papers/a.md", text: "updated")
        let abs = URL(fileURLWithPath: root).appendingPathComponent("vault/papers/a.md")
        #expect(try String(contentsOf: abs, encoding: .utf8) == "updated")
    }

    @Test func createNoteCreatesParentDirsAndFile() async throws {
        let (root, client) = try makeWorkspace()
        try await client.createNote(path: "vault/notes/idea-1.md", text: "draft")
        let abs = URL(fileURLWithPath: root).appendingPathComponent("vault/notes/idea-1.md")
        #expect(try String(contentsOf: abs, encoding: .utf8) == "draft")
    }

    @Test func trashRoundTrip() async throws {
        let (root, client) = try makeWorkspace()
        try await client.createNote(path: "vault/notes/x.md", text: "bye")
        let trashRel = try await client.moveToTrash(path: "vault/notes/x.md")
        #expect(trashRel.hasPrefix("vault/notes/.trash/"))
        let original = URL(fileURLWithPath: root).appendingPathComponent("vault/notes/x.md")
        #expect(FileManager.default.fileExists(atPath: original.path) == false)
        let items = try await client.listTrash()
        #expect(items.count == 1)
        let name = items[0].name
        #expect(name.hasPrefix("x.") && name.hasSuffix(".md"))
        let restoredRel = try await client.restoreTrash(name: name)
        #expect(restoredRel == "vault/notes/x.md")
        #expect(FileManager.default.fileExists(atPath: original.path) == true)
        #expect(try await client.listTrash() == [])
    }

    @Test func purgeRemovesTrashItem() async throws {
        let (_, client) = try makeWorkspace()
        try await client.createNote(path: "vault/notes/y.md", text: "bye")
        _ = try await client.moveToTrash(path: "vault/notes/y.md")
        let name = try await client.listTrash()[0].name
        try await client.purgeTrash(name: name)
        #expect(try await client.listTrash() == [])
    }

    @Test func indexDelegatesEmptyWhenNoDB() async throws {
        let (_, client) = try makeWorkspace()
        #expect(try await client.index() == [])
        #expect(try await client.search(SearchQuery(q: "anything")) == [])
    }
}
