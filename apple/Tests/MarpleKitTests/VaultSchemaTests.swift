import XCTest
@testable import MarpleKit

final class VaultSchemaTests: XCTestCase {

    // 内置别名表必须逐字复刻 IndexedEntry.swift 的现状回退链
    func testBuiltinAuthorAliases() {
        let aliases = VaultSchema.builtin.entityAliases["author"]
        XCTAssertEqual(aliases, [
            VaultSchema.FieldAlias("author"),
            VaultSchema.FieldAlias("authors"),
            VaultSchema.FieldAlias("speaker", onlyForType: "talk"),
            VaultSchema.FieldAlias("creator", onlyForType: "image"),
        ])
    }

    func testBuiltinJournalAndTopicAliases() {
        XCTAssertEqual(VaultSchema.builtin.entityAliases["journal"],
                       [VaultSchema.FieldAlias("journal")])
        XCTAssertEqual(VaultSchema.builtin.entityAliases["topic"],
                       [VaultSchema.FieldAlias("topics")])
    }

    // 内置显示表必须逐字复刻 Marple/Shared/TypeIcon.swift 的现状 switch
    func testBuiltinDisplayMatchesLegacyTypeIcon() {
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
            XCTAssertEqual(d.symbol, symbol, "\(type)")
            XCTAssertEqual(d.tint, tint, "\(type)")
        }
    }
}
