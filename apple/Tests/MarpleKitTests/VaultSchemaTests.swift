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
}
