import Foundation
import GRDB
import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct ArchiveCompatibilityTests {
    private let path = "vault/archives/screen-discussion/archive.md"
    private let minimal = """
    ---
    type: archive
    title: 手机屏幕色偏与二手回收估价的评论截图
    kind: thread
    created: 2026-09-20
    source: Capacities 转存截图
    ---
    """
    private let full = """
    ---
    type: archive
    title: 手机屏幕色偏与二手回收估价的讨论
    kind: thread
    created: 2026-09-20
    creator: [某用户]
    date: 2025-08-30
    source: 某手机论坛
    url: https://example.com/threads/12345
    themes: [屏幕色偏, 二手交易]
    topics: [screen-history]
    rating: 4
    ---
    仅保存来源链接，没有原件或附件。
    """

    private func indexed(_ text: String) throws -> IndexedEntry {
        let outcome = buildIndexedEntry(text: text, rel: path, fileStem: "archive",
                                        sourceSlugs: ["archive"], mtimeMs: nil)
        guard case .indexed(let entry) = outcome else {
            throw NSError(domain: "ArchiveCompatibility", code: 1)
        }
        return entry
    }

    @Test func minimalArchiveNeedsNeitherAttachmentsNorBodySections() throws {
        for kind in ["patent", "thread", "post", "video", "image", "webpage", "document"] {
            let row = try indexed(minimal.replacingOccurrences(of: "kind: thread", with: "kind: \(kind)"))
            #expect(row.entryType == "archive" && row.kind == kind)
            #expect(row.created == "2026-09-20")
            #expect(row.date == nil && row.url == nil && row.author.isEmpty)
            #expect(!row.hasPDF && row.pdfSlug == nil && row.media == nil && row.width == nil)
        }
        let missingCreated = try indexed(full.replacingOccurrences(of: "created: 2026-09-20\n", with: ""))
        #expect(missingCreated.created == nil)
        #expect(missingCreated.date == "2025-08-30")
    }

    @Test func diskIndexSearchRelationsAndOldSchemaUpgrade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            path: full,
            "vault/archives/minimal/archive.md": minimal,
            "vault/notes/screen.md": "---\ntype: note\ntitle: 个人思考\nannotates: \(path)\n---\n",
            "vault/topics/screen-history/00-overview.md": "---\ntype: topic\nkind: overview\n---\n# 屏幕研究\n",
            "vault/authors/creator.md": "---\ntype: author\nname: 某用户\n---\n",
        ]
        for (relative, text) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let indexer = VaultIndexer(workspaceRoot: root.path)
        #expect(try indexer.buildFull() == files.count)
        let dbPath = root.appendingPathComponent(".marple/index.sqlite").path
        let reader = IndexDatabase(indexDBPath: dbPath)
        let entries = try reader.loadEntries()
        let archive = try #require(entries.first { $0.path == path })
        #expect(archive.type == .archive && archive.kind == "thread")
        #expect(archive.author == ["某用户"] && archive.ratingScore == 4)
        #expect(archive.created == "2026-09-20" && archive.date == "2025-08-30")
        #expect(archive.url == "https://example.com/threads/12345")
        #expect(entriesForPane(.type(.archive), in: entries).count == 2)
        #expect(entriesForPane(.theme("屏幕色偏"), in: entries) == [archive])
        #expect(applyFilters(entries, [FilterClause(field: .type, op: .is_, value: "archive")], match: .all).count == 2)
        for query in ["某用户", "某手机论坛", "https://example.com/threads/12345"] {
            #expect(searchEntries(entries, query).contains { $0.entry.path == path }, "query=\(query)")
        }
        for query in ["手机", "某用户", "某手机论坛", "12345"] {
            let hits = try reader.search(query, type: .archive, minRating: 4, theme: "屏幕色偏", limit: 10)
            #expect(hits.map(\.entry) == [archive]) // LIKE and FTS both retain date/url.
        }
        let graph = RelationGraph.build(entries)
        let topic = try #require(entries.first { $0.type == .topic })
        #expect(relations(for: topic, in: entries, graph: graph,
                          topicMembership: buildTopicMembership(entries)).topicMembers == [archive])
        #expect(relations(for: archive, in: entries, graph: graph).annotations.map(\.path) == ["vault/notes/screen.md"])
        #expect(graph.targets(of: path, kind: .authoredBy).map(\.path) == ["vault/authors/creator.md"])
        #expect(containerContext(for: archive, in: entries) == nil)
        for target in [path, "archives/screen-discussion/archive", archive.title!] {
            #expect(NameResolver.resolveWikilink(target, in: entries) == archive)
        }
        #expect(try PropertyListDecoder().decode(Entry.self, from: PropertyListEncoder().encode(archive)) == archive)
        let edited = archive.with(title: "新标题")
        #expect(edited.date == archive.date && edited.url == archive.url && edited.created == archive.created)

        // A pre-archive index must rebuild even when no markdown file has changed.
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE entries DROP COLUMN date; ALTER TABLE entries DROP COLUMN url;")
        }
        #expect(!indexer.canSkipFullBuild())
        #expect(try indexer.reconcile().upserted == files.count)
        #expect(indexer.canSkipFullBuild())
        #expect(try reader.loadEntries().first { $0.path == path } == archive)
    }

    @MainActor @Test func inspectorAndCreatorEditsRespectArchiveFields() async throws {
        let row = try indexed(full)
        let archive = Entry(path: path, type: .archive, title: row.title, author: row.author,
                            year: nil, ratingScore: row.ratingScore, themes: row.themes ?? [],
                            preview: row.preview, hasPDF: false, source: row.source, kind: row.kind,
                            created: row.created, date: row.date, url: row.url)
        #expect(AppPresentation.entryTypeLabel(.archive) == "档案")
        #expect(EntryType.modeled.contains(.archive))
        #expect(inspectorInfoRows(for: archive) == [
            .authors,
            .readOnlyScalar(label: "类型", value: "讨论串", copyValue: "thread"),
            .readOnlyScalar(label: "建档日期", value: "2026-09-20", copyValue: nil),
            .readOnlyScalar(label: "发布日期", value: "2025-08-30", copyValue: nil),
            .readOnlyScalar(label: "来源", value: "某手机论坛", copyValue: nil),
            .linkedScalar(label: "原始链接", value: archive.url!, path: archive.url!, copyValue: archive.url),
            .rating,
        ])
        let schema = SchemaSnapshot(requiredByType: ["archive": ["title", "kind", "created"]])
        #expect(VaultConformance.check(archive, against: schema)?.isConforming == true)
        #expect(VaultConformance.check(archive.with(created: .some(nil)), against: schema)?.missingRequired == ["created"])
        let client = StubVaultClient(entries: [archive], texts: [path: full])
        let model = AppModel(client: client)
        await model.loadIndex()
        model.select(pane: .type(.archive))
        for _ in 0..<200 where model.visibleEntries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.visibleEntries == [archive])
        await model.open(path)
        await model.setAuthor(["新发布者"])
        let saved = try #require(client.writeLog.last?.text)
        let reparsed = try indexed(saved)
        #expect(reparsed.author == ["新发布者"])
        #expect(saved.contains("creator:") && !saved.contains("author:"))
        #expect(reparsed.created == archive.created && reparsed.date == archive.date && reparsed.url == archive.url)
        #expect(model.openEntry?.date == archive.date && model.openEntry?.url == archive.url)
    }
}
