import Foundation
import Testing
import Darwin
@testable import MarpleKit

struct ArchiveCollectionsTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("field-collections-\(UUID())").resolvingSymlinksInPath()
        for (path, text) in [
            "vault/archives/a/archive.md": "---\ntype: archive\ntitle: A\ntopics: [one, two]\n---\n[original](originals/photo.png)\n[Note](../../notes/n.md)\n",
            "vault/archives/a/originals/photo.png": "original bytes",
            "vault/archives/legacy/collection.md": "# Old folder title\nKeep this note.\n",
            "vault/archives/legacy/b/archive.md": "---\ntype: archive\ntitle: B\ncollection: Existing\n---\nB\n",
            "vault/notes/n.md": "[[vault/archives/a/archive.md|A]]\n[Archive](../archives/a/archive.md#part)\n"
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func assignRenameRemovePreservesPathsBodiesAndOtherFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        let original = try String(contentsOf: root.appendingPathComponent("vault/archives/a/archive.md"), encoding: .utf8)
        let note = try Data(contentsOf: root.appendingPathComponent("vault/notes/n.md"))
        let marker = try Data(contentsOf: root.appendingPathComponent("vault/archives/legacy/collection.md"))
        var command = ArchiveCollectionCommand(action: "assign", paths: ["vault/archives/a"], name: "维修: A/B", dryRun: true)
        #expect(try store.execute(command).moves.isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("vault/archives/a/archive.md"), encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".marple").path))
        command.dryRun = false; command.requestID = UUID().uuidString
        let assigned = try store.execute(command)
        #expect(assigned.moves.isEmpty)
        #expect(assigned.inventory.collections.first { $0.title == "维修: A/B" }?.members == ["vault/archives/a/archive.md"])
        #expect(try store.execute(command).replayed)
        #expect(try store.execute(.init(action: "status", requestID: command.requestID)).replayed)
        _ = try store.execute(.init(action: "rename", paths: ["维修: A/B"], name: "Existing", requestID: UUID().uuidString))
        #expect(try store.inventory().collections.count == 1)
        #expect(try store.inventory().collections[0].members.count == 2)
        _ = try store.execute(.init(action: "remove", paths: ["vault/archives/a"], requestID: UUID().uuidString))
        #expect(try String(contentsOf: root.appendingPathComponent("vault/archives/a/archive.md"), encoding: .utf8) == original)
        #expect(try Data(contentsOf: root.appendingPathComponent("vault/notes/n.md")) == note)
        #expect(try Data(contentsOf: root.appendingPathComponent("vault/archives/legacy/collection.md")) == marker)
        #expect(try String(contentsOf: root.appendingPathComponent("vault/archives/a/originals/photo.png"), encoding: .utf8) == "original bytes")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("vault/archives").path).sorted() == ["a", "legacy"])
    }

    @Test func inventoryUsesFieldsNotLegacyFolderNames() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        let inventory = try store.inventory()
        #expect(inventory.collections.map(\.title) == ["Existing"])
        #expect(inventory.fields?["vault/archives/a/archive.md"]?["topics"] == ["one", "two"])
        #expect(inventory.ungrouped == ["vault/archives/a/archive.md"])
        _ = try store.execute(.init(action: "remove", paths: ["vault/archives/legacy/b"], requestID: UUID().uuidString))
        #expect(try store.inventory().collections.isEmpty)
        #expect(try store.inventory().ungrouped.count == 2)
    }

    @Test func invalidBatchAndOldDirectoryCommandsNeverWriteDocuments() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        let before = try Data(contentsOf: root.appendingPathComponent("vault/archives/a/archive.md"))
        for command in [
            ArchiveCollectionCommand(action: "assign", paths: ["vault/archives/a", "vault/archives/missing"], name: "X", requestID: UUID().uuidString),
            .init(action: "create", name: "Empty", requestID: UUID().uuidString),
            .init(action: "move", paths: ["vault/archives/a"], destination: "vault/archives/legacy", requestID: UUID().uuidString),
            .init(action: "assign", paths: ["vault/archives/a"], name: "two\nlines", requestID: UUID().uuidString)
        ] { #expect(throws: (any Error).self) { try store.execute(command) } }
        #expect(try Data(contentsOf: root.appendingPathComponent("vault/archives/a/archive.md")) == before)
    }

    @Test func absolutePathsAcceptedAndSymlinksTraversalRejected() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        _ = try store.execute(.init(action: "assign", paths: [root.appendingPathComponent("vault/archives/a/archive.md").path], name: "true", requestID: UUID().uuidString))
        #expect(try store.inventory().collections.contains { $0.title == "true" })
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("vault/archives/link"), withDestinationURL: root.appendingPathComponent("vault/archives/a"))
        for path in ["vault/archives/link/archive.md", "vault/archives/../notes/n.md"] {
            #expect(throws: (any Error).self) { try store.execute(.init(action: "assign", paths: [path], name: "Bad", requestID: UUID().uuidString)) }
        }
    }

    @Test func collectionListsAreRejectedAndTopicsRemainMultivalued() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("vault/archives/legacy/b/archive.md")
        let text = "---\ntype: archive\ncollection: [A, B]\n---\nB"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let store = ArchiveCollections(workspaceRoot: root.path)
        #expect(try store.inventory().issues.count == 1)
        #expect(try store.inventory().collections.isEmpty)
        #expect(throws: (any Error).self) { try store.execute(.init(action: "assign", paths: ["vault/archives/a", "vault/archives/legacy/b"], name: "C", requestID: UUID().uuidString)) }
        #expect(try store.inventory().ungrouped.count == 2)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func pendingJournalAndActiveWriterBlockMutations() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        let id = UUID().uuidString
        let command = ArchiveCollectionCommand(action: "assign", paths: ["vault/archives/a"], name: "completed", requestID: id)
        #expect(try store.execute(command).replayed == false)
        #expect(try store.execute(command).replayed == true)
        #expect(throws: (any Error).self) { try store.execute(.init(action: "assign", paths: ["vault/archives/a"], name: "other", requestID: id)) }
        let fd = Darwin.open(root.appendingPathComponent(".marple/archive-collections.lock").path, O_RDWR)
        defer { Darwin.close(fd) }
        #expect(flock(fd, LOCK_SH | LOCK_NB) == 0)
        #expect(throws: (any Error).self) { try store.execute(.init(action: "remove", paths: ["vault/archives/a"], requestID: UUID().uuidString)) }
        flock(fd, LOCK_UN)
        let journal = root.appendingPathComponent(".marple/collection-operations/\(id).json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        json.removeValue(forKey: "result")
        try JSONSerialization.data(withJSONObject: json).write(to: journal)
        #expect(throws: (any Error).self) { try store.execute(.init(action: "remove", paths: ["vault/archives/a"], requestID: UUID().uuidString)) }
    }

    @Test func scalarPatchPreservesCRLFAndReplacesFoldedValues() {
        let raw = "---\r\ntype: archive\r\ncollection: >-\r\n  Old name\r\ntopics: [a, b]\r\n---\r\nBody\r\n"
        let next = FrontmatterPatch.setCollection(raw, value: "New")
        #expect(next == "---\r\ntype: archive\r\ncollection: New\r\ntopics: [a, b]\r\n---\r\nBody\r\n")
    }
}
