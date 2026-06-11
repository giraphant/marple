import Foundation
import Testing
@testable import MarpleKit

@Suite struct VaultSchemaTests {

    // 内置别名表必须逐字复刻 IndexedEntry.swift 的现状回退链
    @Test func builtinAuthorAliases() {
        let aliases = VaultSchema.builtin.entityAliases["author"]
        #expect(aliases == [
            VaultSchema.FieldAlias("author"),
            VaultSchema.FieldAlias("authors"),
            VaultSchema.FieldAlias("speaker", onlyForType: "talk"),
            VaultSchema.FieldAlias("creator", onlyForType: "image"),
        ])
    }

    @Test func builtinJournalAndTopicAliases() {
        #expect(VaultSchema.builtin.entityAliases["journal"] ==
                [VaultSchema.FieldAlias("journal")])
        #expect(VaultSchema.builtin.entityAliases["topic"] ==
                [VaultSchema.FieldAlias("topics")])
    }

    // 内置显示表必须逐字复刻 Marple/Shared/TypeIcon.swift 的现状 switch
    @Test func builtinDisplayMatchesLegacyTypeIcon() {
        let expected: [(EntryType, String, String)] = [
            (.paper,      "doc.text",                 "blue"),
            (.book,       "book",                     "orange"),
            (.author,     "person",                   "purple"),
            (.topic,      "square.stack.3d.up",       "teal"),
            (.journal,    "newspaper",                "green"),
            (.chapter,    "list.bullet.rectangle",    "indigo"),
            (.note,       "note.text",                "yellow"),
            (.image,      "photo",                    "pink"),
            (.talk,       "waveform",                 "red"),
            (.transcript, "text.quote",               "brown"),
            (.other("x"), "questionmark.square.dashed", "gray"),
        ]
        for (type, symbol, tint) in expected {
            let d = VaultSchema.builtin.display(for: type)
            #expect(d.symbol == symbol, "\(type)")
            #expect(d.tint == tint, "\(type)")
        }
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("vault/schema"),
            withIntermediateDirectories: true)
        return root
    }

    @Test func loadWithoutFileReturnsBuiltin() throws {
        let root = try makeWorkspace()
        #expect(VaultSchema.load(workspaceRoot: root.path) == .builtin)
    }

    @Test func loadAppliesPerKeyOverrides() throws {
        let root = try makeWorkspace()
        let yaml = """
        entities:
          author:
            fields:
              - author
              - field: translator
                type: book
        display:
          paper:
            symbol: doc.richtext
            tint: mint
        """
        try yaml.write(to: root.appendingPathComponent("vault/schema/schema.yaml"),
                       atomically: true, encoding: .utf8)
        let schema = VaultSchema.load(workspaceRoot: root.path)
        // author 整 key 替换
        #expect(schema.entityAliases["author"] == [
            VaultSchema.FieldAlias("author"),
            VaultSchema.FieldAlias("translator", onlyForType: "book"),
        ])
        // 未提及的 key 保持内置
        #expect(schema.entityAliases["journal"] == VaultSchema.builtin.entityAliases["journal"])
        #expect(schema.display(for: .paper) ==
                VaultSchema.TypeDisplay(symbol: "doc.richtext", tint: "mint"))
        #expect(schema.display(for: .book) == VaultSchema.builtin.display(for: .book))
    }

    @Test func loadMalformedFileReturnsBuiltin() throws {
        let root = try makeWorkspace()
        try "][ not yaml ][".write(to: root.appendingPathComponent("vault/schema/schema.yaml"),
                                   atomically: true, encoding: .utf8)
        #expect(VaultSchema.load(workspaceRoot: root.path) == .builtin)
    }
}
