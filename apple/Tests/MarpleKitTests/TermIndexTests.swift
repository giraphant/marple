import Foundation
import GRDB
import Testing
@testable import MarpleKit

@Suite("TermParser")
struct TermParserTests {
    @Test func tablesPreserveSingleTermsAndProvenance() {
        let text = """
        ---
        title: Test
        ---
        ## 关键概念

        | 概念 | 英文 | 定义 |
        | --- | --- | --- |
        | **惯习** | `Habitus` | 身体化的倾向 |
        | 能动性 | agency / human agency | 行动能力 |
        | 具身性 | [Embodiment](https://example.com) | 身体与世界 |
        | - | Missing | 忽略 |

        ### 补充

        | 中文 | English term | Meaning |
        | --- | --- | --- |
        | 社会资本 | Social Capital<br>social resources | 联系 |

        ## 其他表格

        | 概念 | 英文 |
        | --- | --- |
        | 忽略 | Ignore |
        """
        let records = TermParser.parse(text, path: "vault/a.md")
        #expect(records.count == 2)
        #expect(records[0].chinese == "惯习")
        #expect(records[0].english == "Habitus")
        #expect(records[0].chineseCell == "惯习")
        #expect(records[0].definition == "身体化的倾向")
        #expect(records[0].line == 8)
        #expect(records.allSatisfy { $0.path == "vault/a.md" })
        #expect(!records.contains { $0.chinese == "能动性" || $0.chinese == "社会资本" })
        #expect(records.contains { $0.english == "Embodiment" })
    }

    @Test(arguments: [" / ", "/", "／", ";", "；", "、", "<br>", "<br/>"])
    func eitherCompoundCellSkipsTheWholeRow(separator: String) {
        let text = """
        ## 关键概念
        | 概念 | 英文 |
        | --- | --- |
        | 惯习\(separator)习性 | habitus |
        | 能动性 | agency\(separator)human agency |
        """
        #expect(TermParser.parse(text, path: "vault/a.md").isEmpty)
    }

    @Test func codeAndMalformedTablesDoNotCreateRelations() {
        let text = """
        ```markdown
        ## 关键概念
        | 概念 | 英文 |
        | --- | --- |
        | 伪造 | fake |
        ```
        ## Key Concepts
        | 中文 | 解释 |
        | --- | --- |
        | 错误表头 | ignored |

        | English | Chinese | Definition |
        | --- | --- | --- |
        | sense-making | 意义建构 | A \\| B |
        | | 空行 | |
        | [[技术中介|技术中介 | Technological Mediation | Broken link shifts columns |
        | [[交感性\\|交感性(Intersensoriality)][6]] | Intersensoriality | Broken citation |
        """
        let records = TermParser.parse(text, path: "vault/a.md")
        #expect(records.count == 1)
        #expect(records.first?.english == "sense-making")
        #expect(records.first?.definition == "A | B")
        #expect(TermParser.key("  Social   CAPITAL\n") == "social capital")
    }

    @Test func wikilinksUseVisibleTermWithoutShiftingTableColumns() {
        let text = """
        ## 关键概念

        | 概念 | 英文 | 定义 |
        | --- | --- | --- |
        | [[概念隐喻|概念隐喻理论]] | Conceptual Metaphor Theory | [[理论|说明]] |
        | [[习性]] | habitus | 倾向 |
        """
        let records = TermParser.parse(text, path: "vault/a.md")
        #expect(records.count == 2)
        #expect(records[0].chinese == "概念隐喻理论")
        #expect(records[0].english == "Conceptual Metaphor Theory")
        #expect(records[0].definition == "说明")
        #expect(records[0].line == 5)
        #expect(records[1].chinese == "习性")
    }
}

@Suite("TermIndex")
struct TermIndexTests {
    func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("vault"), withIntermediateDirectories: true)
        return root
    }

    func write(_ root: URL, _ path: String, _ rows: String) throws {
        let text = "## 关键概念\n\n| 概念 | 英文 | 定义 |\n| --- | --- | --- |\n" + rows
        try text.write(to: root.appendingPathComponent("vault/" + path), atomically: true, encoding: .utf8)
    }

    @Test func incrementalChangesRetainOtherSourcesAndSurviveReopening() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.md", "| 惯习 | Habitus | 倾向 |\n| 习性 | habitus | 译名 |")
        try write(root, "b.md", "| 惯习 | habitus | 来自另一篇 |")
        try write(root, ".hidden.md", "| 不要 | hidden | |")
        let index = TermIndex(workspaceRoot: root.path)
        #expect(try await index.status() == nil)
        let first = try await index.refresh()
        #expect(first.terms == 3 && first.relations == 2)
        #expect(first.sourceDocuments == 2 && first.scannedDocuments == 2)
        #expect(try await index.refresh() == first)
        let matches = try await index.lookup(" 惯习 ")
        #expect(matches.count == 1 && matches[0].sources.count == 2)
        #expect(Set(try await index.lookup("HABITUS").map(\.term)) == ["惯习", "习性"])

        try write(root, "a.md", "| 具身性 | Embodiment | 身体 |")
        _ = try await index.refresh()
        #expect(try await index.lookup("惯习").first?.sources.count == 1)
        #expect(try await index.lookup("习性").isEmpty)
        try FileManager.default.moveItem(at: root.appendingPathComponent("vault/b.md"),
            to: root.appendingPathComponent("vault/c.md"))
        _ = try await index.refresh()
        let renamed = try await index.lookup("惯习")
        #expect(renamed.first?.sources.first?.path == "vault/c.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent("vault/c.md"))
        _ = try await index.refresh()
        #expect(try await index.lookup("惯习").isEmpty)
        let beforeRebuild = try await index.lookup("embodiment")
        _ = try await index.refresh(rebuild: true)
        let reopened = TermIndex(workspaceRoot: root.path)
        #expect(try await reopened.lookup("embodiment") == beforeRebuild)
        try "No glossary anymore".write(to: root.appendingPathComponent("vault/a.md"), atomically: true, encoding: .utf8)
        let empty = try await index.refresh()
        #expect(empty.terms == 0 && empty.scannedDocuments == 1 && empty.sourceDocuments == 0)
    }

    @Test func failedRebuildRollsBackAndMissingVaultDoesNotEraseIndex() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.md", "| 能动性 | agency | 行动 |")
        let index = TermIndex(workspaceRoot: root.path)
        let before = try await index.refresh()
        try write(root, "a.md", "| 具身性 | embodiment | 身体 |")
        try Data([0xFF, 0xFE, 0xFF]).write(to: root.appendingPathComponent("vault/z.md"))
        await #expect(throws: (any Error).self) { try await index.refresh(rebuild: true) }
        #expect(try await index.status() == before)
        #expect(try await index.lookup("agency").first?.term == "能动性")
        try FileManager.default.moveItem(at: root.appendingPathComponent("vault"), to: root.appendingPathComponent("offline"))
        await #expect(throws: (any Error).self) { try await index.refresh() }
        #expect(try await index.status() == before)
    }

    @Test func parserVersionForcesReparseAndOrdinaryRebuildIsIndependent() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.md", """
        | 能动性 | agency | 行动 |
        | 效力与能动性的不对称 | efficacy / agency; asymmetrical-reciprocal relation | |
        """)
        let index = TermIndex(workspaceRoot: root.path)
        _ = try await index.refresh()
        try await DatabaseQueue(path: index.databasePath).write { db in
            // Simulate a v1 index with the old cross-product pair and unchanged files.
            try db.execute(sql: """
                INSERT OR REPLACE INTO pairs
                SELECT path, line + 1, '效力与能动性的不对称', 'agency',
                    '效力与能动性的不对称', 'agency', '效力与能动性的不对称',
                    'efficacy / agency; asymmetrical-reciprocal relation', NULL
                FROM pairs WHERE chinese_key = '能动性';
                UPDATE meta SET value = '1' WHERE key = 'parser_version';
                """)
        }
        #expect(!(try await index.lookup("效力与能动性的不对称")).isEmpty)
        _ = try await index.refresh()
        #expect(try await index.lookup("效力与能动性的不对称").isEmpty)
        #expect(try await index.lookup("agency").count == 1)
        _ = try VaultIndexer(workspaceRoot: root.path).buildFull()
        #expect(try await index.lookup("agency").count == 1)
    }

    @Test func symbolicFileAliasesKeepDistinctSourcePaths() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.md", "| 惯习 | habitus | 倾向 |")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("vault/b.md").path,
            withDestinationPath: "a.md")
        let index = TermIndex(workspaceRoot: root.path)
        let status = try await index.refresh()
        #expect(status.relations == 1 && status.sourceDocuments == 2)
        let match = try #require(try await index.lookup("惯习").first)
        #expect(Set(match.sources.map(\.path)) == ["vault/a.md", "vault/b.md"])
        try write(root, "a.md", "| 能动性 | agency | 行动 |")
        _ = try await index.refresh()
        #expect(try await index.lookup("惯习").isEmpty)
        #expect(try await index.lookup("agency").first?.sources.count == 2)
    }
}
