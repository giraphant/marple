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

    @Test func imageOriginalURLResolvesOriginalBesideImageMarkdown() async throws {
        let (root, client) = try makeWorkspace()
        let imageDir = URL(fileURLWithPath: root).appendingPathComponent("vault/images/loop")
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        try "---\ntype: image\ntitle: Loop\n---\n".write(
            to: imageDir.appendingPathComponent("image.md"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageDir.appendingPathComponent("original.png"))

        let url = try await client.imageOriginalURL(forImageEntryPath: "vault/images/loop/image.md")

        #expect(url?.path == imageDir.appendingPathComponent("original.png").path)
    }

    @Test func createImageObjectCopiesOriginalAndWritesMetadata() async throws {
        let (root, client) = try makeWorkspace()
        let source = URL(fileURLWithPath: root).appendingPathComponent("AI Agent Loop Diagram.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)

        let entry = try await client.createImageObject(from: source, title: nil)

        #expect(entry.path == "vault/images/ai-agent-loop-diagram/image.md")
        #expect(entry.type == .image)
        #expect(entry.title == "AI Agent Loop Diagram")
        let imageDir = URL(fileURLWithPath: root).appendingPathComponent("vault/images/ai-agent-loop-diagram")
        #expect(FileManager.default.fileExists(atPath: imageDir.appendingPathComponent("original.png").path))
        let metadata = try String(contentsOf: imageDir.appendingPathComponent("image.md"), encoding: .utf8)
        #expect(metadata.contains("type: image"))
        #expect(metadata.contains("title: AI Agent Loop Diagram"))
    }

    @Test func indexDelegatesEmptyWhenNoDB() async throws {
        let (_, client) = try makeWorkspace()
        #expect(try await client.index() == [])
        #expect(try await client.search(SearchQuery(q: "anything")) == [])
    }
}
