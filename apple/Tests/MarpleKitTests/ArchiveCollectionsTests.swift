import Foundation
import Testing
import Darwin
@testable import MarpleKit

struct ArchiveCollectionsTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collections-\(UUID())").resolvingSymlinksInPath()
        for (path, text) in [
            "vault/archives/a/archive.md": "---\ntype: archive\ntitle: A\n---\n[original](originals/photo.png)\n[Note](../../notes/n.md)\n",
            "vault/archives/a/originals/photo.png": "original bytes",
            "vault/archives/group/collection.md": "# 我的合集\n\nKeep this note.\n",
            "vault/notes/n.md": "---\narchives: [vault/archives/a/archive.md]\n---\n[[vault/archives/a/archive.md|A]]\n[Archive](../archives/a/archive.md#part)\nUnrelated prose: vault/archives/a/archive.md\n"
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    @Test func moveRenameMoveOutAndReplay() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        let initial = try store.inventory()
        #expect(initial.collections.first?.title == "我的合集")
        var command = ArchiveCollectionCommand(action: "move", paths: initial.ungrouped, destination: "vault/archives/group", dryRun: true)
        #expect(try store.execute(command).moves.first?.to == "vault/archives/group/a")
        #expect(try store.inventory() == initial)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".marple").path))
        command.dryRun = false; command.requestID = UUID().uuidString
        let moved = try store.execute(command)
        #expect(moved.inventory.ungrouped.isEmpty)
        #expect(try store.execute(command).moves == moved.moves)
        let body = try String(contentsOf: root.appendingPathComponent("vault/archives/group/a/archive.md"), encoding: .utf8)
        #expect(body.contains("(originals/photo.png)"))
        #expect(body.contains("(../../../notes/n.md)"))
        let note = try String(contentsOf: root.appendingPathComponent("vault/notes/n.md"), encoding: .utf8)
        #expect(note.contains("  - vault/archives/group/a/archive.md"))
        #expect(note.contains("[[vault/archives/group/a/archive.md|A]]"))
        #expect(note.contains("(../archives/group/a/archive.md#part)"))
        #expect(note.contains("Unrelated prose: vault/archives/a/archive.md"))
        _ = try store.execute(.init(action: "rename", paths: ["vault/archives/group"], name: "新合集", requestID: UUID().uuidString))
        #expect(try store.inventory().collections[0].title == "新合集")
        #expect(try String(contentsOf: root.appendingPathComponent("vault/archives/新合集/collection.md"), encoding: .utf8).contains("Keep this note."))
        _ = try store.execute(.init(action: "move", paths: ["vault/archives/新合集/a"], destination: "vault/archives", requestID: UUID().uuidString))
        #expect(try store.inventory().ungrouped == initial.ungrouped)
        #expect(try String(contentsOf: root.appendingPathComponent("vault/archives/a/originals/photo.png"), encoding: .utf8) == "original bytes")
    }
    @Test func pendingJournalAndActiveWriterBlockMutations() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        let id = UUID().uuidString
        let command = ArchiveCollectionCommand(action: "create", name: "completed", requestID: id)
        #expect(try store.execute(command).replayed == false)
        #expect(try store.execute(command).replayed == true)
        #expect(throws: (any Error).self) { try store.execute(.init(action: "create", name: "other", requestID: id)) }
        let fd = Darwin.open(root.appendingPathComponent(".marple/archive-collections.lock").path, O_RDWR)
        defer { Darwin.close(fd) }
        #expect(flock(fd, LOCK_SH | LOCK_NB) == 0)
        #expect(throws: (any Error).self) { try store.execute(.init(action: "create", name: "busy", requestID: UUID().uuidString)) }
        flock(fd, LOCK_UN)
        let journal = root.appendingPathComponent(".marple/collection-operations/\(id).json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        json.removeValue(forKey: "result")
        try JSONSerialization.data(withJSONObject: json).write(to: journal)
        #expect(throws: (any Error).self) { try store.execute(.init(action: "create", name: "blocked", requestID: UUID().uuidString)) }
        #expect(try store.inventory().collections.count == 2)
    }

    @Test func emptyRootAbsolutePathsAndDuplicateSlugs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collection-empty-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        _ = try store.execute(.init(action: "create", name: "合集", requestID: UUID().uuidString))
        let a = root.appendingPathComponent("vault/archives/a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try "# A".write(to: a.appendingPathComponent("archive.md"), atomically: true, encoding: .utf8)
        let physical = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("vault/archives"), includingPropertiesForKeys: nil).first { $0.lastPathComponent == "a" }!
        _ = try store.execute(.init(action: "move", paths: [physical.path], destination: "vault/archives/合集", requestID: UUID().uuidString))
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try "# Duplicate".write(to: a.appendingPathComponent("archive.md"), atomically: true, encoding: .utf8)
        #expect(try store.inventory().issues.contains { $0.contains("Duplicate") })
        #expect(throws: (any Error).self) { try store.execute(.init(action: "create", name: "blocked", requestID: UUID().uuidString)) }
    }

    @Test func referencesPreserveCodeAndQuotedPaths() throws {
        let move = ArchiveCollectionChange(from: "vault/archives/旧 合集,a", to: "vault/archives/新 合集,b")
        let path = "vault/archives/旧 合集,a/item/archive.md"
        let text = "---\narchives: ['\(path)']\n---\n`[[\(path)]]`\n```md\n[[\(path)]]\n```\n[[\(path)|A]]\n"
        let rewritten = ArchiveCollectionReferences.rewrite(text, at: "vault/notes/a.md", moves: [move])
        #expect(rewritten.contains("`[[\(path)]]`"))
        #expect(rewritten.contains("```md\n[[\(path)]]\n```"))
        #expect(rewritten.contains("[[vault/archives/新 合集,b/item/archive.md|A]]"))
        let again = ArchiveCollectionReferences.rewrite(rewritten, at: "vault/notes/a.md", moves: [move])
        #expect(again == rewritten)
    }

    @Test func invalidBatchNeverMovesFirstMember() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        for name in ["../escape", "group", "GROUP", ".hidden", "bad/name", ""] {
            #expect(throws: (any Error).self) { try store.execute(.init(action: "create", name: name, requestID: UUID().uuidString)) }
        }
        let before = try store.inventory()
        #expect(throws: (any Error).self) { try store.execute(.init(action: "move", paths: ["vault/archives/a", "vault/archives/missing"], destination: "vault/archives/group", requestID: UUID().uuidString)) }
        #expect(try store.inventory() == before)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("vault/archives/link"), withDestinationURL: root.appendingPathComponent("vault/archives/a"))
        #expect(throws: (any Error).self) { try store.execute(.init(action: "move", paths: ["vault/archives/link"], destination: "vault/archives/group", requestID: UUID().uuidString)) }
    }
    @Test func emptyMarkerAndCreation() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArchiveCollections(workspaceRoot: root.path)
        try "".write(to: root.appendingPathComponent("vault/archives/group/collection.md"), atomically: true, encoding: .utf8)
        #expect(try store.inventory().collections[0].title == "group")
        _ = try store.execute(.init(action: "create", name: "中文合集", requestID: UUID().uuidString))
        #expect(try store.inventory().collections.contains { $0.title == "中文合集" })
        try "".write(to: root.appendingPathComponent("vault/archives/a/collection.md"), atomically: true, encoding: .utf8)
        #expect(try store.inventory().issues.count == 1)
    }
}
