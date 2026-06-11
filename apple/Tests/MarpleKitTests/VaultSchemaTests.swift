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

    // 规则③路径引用：内置表必须复刻旧 RelationGraph.build 的硬编码 note→annotates
    @Test func builtinPathReferences() {
        #expect(VaultSchema.builtin.pathReferences ==
                [VaultSchema.PathReference(onType: "note", field: "annotates", kind: "annotates")])
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

    @Test func loadOverridesPathReferences() throws {
        let root = try makeWorkspace()
        let yaml = """
        pathReferences:
          - onType: note
            field: annotates
            kind: annotates
          - onType: transcript
            field: annotates
            kind: annotates
        """
        try yaml.write(to: root.appendingPathComponent("vault/schema/schema.yaml"),
                       atomically: true, encoding: .utf8)
        let schema = VaultSchema.load(workspaceRoot: root.path)
        // 整列表替换
        #expect(schema.pathReferences == [
            VaultSchema.PathReference(onType: "note", field: "annotates", kind: "annotates"),
            VaultSchema.PathReference(onType: "transcript", field: "annotates", kind: "annotates"),
        ])
        // 未提及的 key 保持内置
        #expect(schema.entityAliases["author"] == VaultSchema.builtin.entityAliases["author"])
    }

    @Test func loadMalformedFileReturnsBuiltin() throws {
        let root = try makeWorkspace()
        try "][ not yaml ][".write(to: root.appendingPathComponent("vault/schema/schema.yaml"),
                                   atomically: true, encoding: .utf8)
        #expect(VaultSchema.load(workspaceRoot: root.path) == .builtin)
    }

    @Test func indexerUsesSchemaAuthorAliases() {
        let text = """
        ---
        type: book
        title: T
        translator: 张三
        ---
        body
        """
        var schema = VaultSchema.builtin
        schema.entityAliases["author"] = [
            VaultSchema.FieldAlias("author"),
            VaultSchema.FieldAlias("translator", onlyForType: "book"),
        ]
        let outcome = buildIndexedEntry(
            text: text, rel: "vault/books/t/book.md", fileStem: "book",
            sourceSlugs: [], mtimeMs: nil, schema: schema)
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.author == ["张三"])

        // 声明顺序生效：两个别名字段同时存在时，先声明的 author 赢
        let both = """
        ---
        type: book
        title: T
        author: 李四
        translator: 张三
        ---
        body
        """
        let bothOutcome = buildIndexedEntry(
            text: both, rel: "vault/books/t2/book.md", fileStem: "book",
            sourceSlugs: [], mtimeMs: nil, schema: schema)
        guard case .indexed(let bothEntry) = bothOutcome else {
            Issue.record("expected .indexed, got \(bothOutcome)")
            return
        }
        #expect(bothEntry.author == ["李四"])
    }

    // 默认 schema 下既有行为不变：talk 的 speaker 落 author 列
    @Test func indexerDefaultSchemaKeepsTalkSpeakerFold() {
        let text = """
        ---
        type: talk
        title: T
        speaker: 李四
        ---
        body
        """
        let outcome = buildIndexedEntry(
            text: text, rel: "vault/talks/t/talk.md", fileStem: "talk",
            sourceSlugs: [], mtimeMs: nil)
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.author == ["李四"])
    }

    // 类型限定生效：speaker 在非 talk 类型上不折入 author
    @Test func indexerAliasTypeRestriction() {
        let text = """
        ---
        type: note
        title: T
        speaker: 王五
        ---
        body
        """
        let outcome = buildIndexedEntry(
            text: text, rel: "vault/notes/n.md", fileStem: "n",
            sourceSlugs: [], mtimeMs: nil)
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.author == [])
    }

    // MARK: - QUA-222 写回（覆盖最小化 + 往返）

    // 未改动 → 覆盖体只有注释头，落盘表现为「删除文件」，load 退回内置
    @Test func saveBuiltinRemovesFile() throws {
        let root = try makeWorkspace()
        let url = root.appendingPathComponent("vault/schema/schema.yaml")
        try "stale".write(to: url, atomically: true, encoding: .utf8)
        try VaultSchema.builtin.save(workspaceRoot: root.path)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(VaultSchema.load(workspaceRoot: root.path) == .builtin)
    }

    // 只写与内置不同的 key；其余 key 不出现在覆盖体里
    @Test func overrideYAMLEmitsOnlyDiffs() {
        var schema = VaultSchema.builtin
        schema.displayByType["paper"] = .init(symbol: "doc.richtext", tint: "mint")
        let yaml = schema.overrideYAML()
        #expect(yaml.contains("paper:"))
        #expect(yaml.contains("doc.richtext"))
        #expect(yaml.contains("mint"))
        // 未改动的 book / 别名 / 路径引用不写出
        #expect(!yaml.contains("book:"))
        #expect(!yaml.contains("entities:"))
        #expect(!yaml.contains("pathReferences:"))
    }

    // 编辑过的 schema 经 save → load 必须逐字往返
    @Test func saveLoadRoundTrips() throws {
        let root = try makeWorkspace()
        var schema = VaultSchema.builtin
        schema.entityAliases["author"] = [
            .init("author"),
            .init("translator", onlyForType: "book"),
        ]
        schema.entityAliases["editor"] = [.init("editor")]   // 新增实体
        schema.displayByType["paper"] = .init(symbol: "doc.richtext", tint: "mint")
        schema.pathReferences = [
            .init(onType: "note", field: "annotates", kind: "annotates"),
            .init(onType: "transcript", field: "talk", kind: "transcript-of"),
        ]
        try schema.save(workspaceRoot: root.path)
        #expect(VaultSchema.load(workspaceRoot: root.path) == schema)
    }

    @MainActor
    @Test func entryTypeDisplayReadsActiveSchema() {
        defer { VaultSchema.active = .builtin }   // 不污染其它测试
        #expect(EntryType.paper.symbolName == "doc.text")
        #expect(EntryType.paper.tintName == "blue")
        var custom = VaultSchema.builtin
        custom.displayByType["paper"] = .init(symbol: "doc.richtext", tint: "mint")
        VaultSchema.active = custom
        #expect(EntryType.paper.symbolName == "doc.richtext")
        #expect(EntryType.paper.tintName == "mint")
    }
}
