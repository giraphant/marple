import Foundation
import Testing
import MarpleEmbeddings
@testable import Marple
@testable import MarpleKit

@Suite struct TermExpansionTests {
    @Test func depthCyclesAndCompoundQueries() async throws {
        let fixture = TermIndexTests()
        let root = try fixture.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = """
        | 惯习 | habitus | |
        | 习性 | habitus | |
        | 习性 | disposition | |
        | 倾向 | disposition | |
        | 倾向 | propensity | |
        | 性向 | propensity | |
        | 社会资本 | social capital | |
        | 社会 | social | |
        | 艺术 | art | |
        """
        try fixture.write(root, "terms.md", rows)
        try fixture.write(root, "second-source.md", rows)
        let index = TermIndex(workspaceRoot: root.path)
        try await index.refresh()
        #expect(try await index.expandedQueries("惯习", depth: 1) == ["惯习", "habitus"])
        #expect(try await index.expandedQueries("惯习", depth: 2) == ["惯习", "habitus", "习性"])
        #expect(try await index.expandedQueries("惯习", depth: 5) ==
            ["惯习", "habitus", "习性", "disposition", "倾向", "propensity"])
        #expect(try await index.expandedQueries("布迪厄的惯习", depth: 2) ==
            ["布迪厄的惯习", "布迪厄的habitus", "布迪厄的习性"])
        #expect(try await index.expandedQueries("Social Capital and party", depth: 1) ==
            ["Social Capital and party", "社会资本 and party"])
        #expect(try await index.expandedQueries("没有对应词", depth: 2) == ["没有对应词"])
        #expect(try await index.expandedQueries("惯习", depth: 0) == ["惯习"])
    }

    @Test func frequencyCountsDocumentsAndPreservesSoleCandidates() async throws {
        let fixture = TermIndexTests()
        let root = try fixture.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try fixture.write(root, "first.md", """
        | 能动性 | agency | |
        | 能动性 | rare | |
        | 能动性 | RARE | |
        | 能动性 | rare | |
        | 唯一译名 | sole | |
        | 无共识 | one | |
        | 无共识 | two | |
        """)
        try fixture.write(root, "second.md", "| 能动性 | agency | |")
        let index = TermIndex(workspaceRoot: root.path)
        try await index.refresh()
        #expect(try await index.expandedQueries("能动性", depth: 2) == ["能动性", "agency"])
        #expect(try await index.expandedQueries("唯一译名", depth: 2) == ["唯一译名", "sole"])
        #expect(try await index.expandedQueries("sole", depth: 2) == ["sole", "唯一译名"])
        #expect(try await index.expandedQueries("无共识", depth: 2) == ["无共识"])
        // Returning to the source must not promote the other singleton: the
        // sole-candidate exception uses all candidates, including visited ones.
        #expect(try await index.expandedQueries("one", depth: 2) == ["one", "无共识"])
    }

    @Test func keepsFiveMostFrequentCandidatesWithStableTies() async throws {
        let fixture = TermIndexTests()
        let root = try fixture.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = ["a", "b", "c", "d", "e", "f", "z"]
            .map { "| 能动性 | \($0) | |" }.joined(separator: "\n")
        try fixture.write(root, "first.md", rows)
        try fixture.write(root, "second.md", rows)
        try fixture.write(root, "third.md", "| 能动性 | z | |")
        let index = TermIndex(workspaceRoot: root.path)
        try await index.refresh()
        let expected = ["能动性", "a", "b", "c", "d", "z"]
        #expect(try await index.expandedQueries("能动性", depth: 1) == expected)
        #expect(try await index.expandedQueries("能动性", depth: 2) == expected)
        // "f" has one counterpart, but that counterpart's top five exclude f.
        #expect(try await index.expandedQueries("f", depth: 2) == ["f"] + expected)
    }

    @Test func missingIndexAndCancellation() async throws {
        let root = try TermIndexTests().workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = TermIndex(workspaceRoot: root.path)
        #expect(try await index.expandedQueries("惯习", depth: 2) == ["惯习"])
        #expect(!FileManager.default.fileExists(atPath: index.databasePath))
        let task = Task {
            try await Task.sleep(for: .seconds(10))
            return try await index.expandedQueries("惯习", depth: 5)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func repeatedCompoundRowsNeverEnterExpansion() async throws {
        let fixture = TermIndexTests()
        let root = try fixture.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = """
        | 能动性 | agency | 行动能力 |
        | 效力与能动性的不对称 | efficacy / agency; asymmetrical-reciprocal relation | |
        """
        try fixture.write(root, "overview.md", rows)
        try fixture.write(root, "chapter.md", rows)
        let index = TermIndex(workspaceRoot: root.path)
        try await index.refresh()
        #expect(try await index.lookup("agency").map(\.term) == ["能动性"])
        #expect(try await index.expandedQueries("能动性", depth: 2) == ["能动性", "agency"])
    }

    @Test func fusionDeduplicatesAndUsesRanks() {
        let a = hit("a", score: 0.4), b = hit("b", score: 200), c = hit("c", score: 900)
        let result = fuseSearchHits([[a, b, b], [b, c]])
        #expect(result.map(\.entry.path) == ["b", "a", "c"])
        #expect(abs(result[0].score - (1.0 / 62 + 1.0 / 61)) < 0.000001)
        #expect(fuseSearchHits([[a, b]]) == [a, b])
    }

    private func hit(_ path: String, score: Double) -> SearchHit {
        SearchHit(entry: Entry(path: path, type: .note, title: path, author: [], year: nil,
                              ratingScore: 0, themes: [], preview: "", hasPDF: false),
                  score: score, snippet: nil, source: "vec")
    }
}

@Suite @MainActor struct ExpandedAppSearchTests {
    private func fixture(enableExpansion: Bool = true) async throws -> (URL, AppModel, UserDefaults, RecordingSemantic) {
        let root = try TermIndexTests().workspace()
        let rows = "| 惯习 | habitus | |\n| 习性 | habitus | |"
        try TermIndexTests().write(root, "terms.md", rows + "\n| 偶见描述 | habitus | |")
        try TermIndexTests().write(root, "second-source.md", rows)
        for (name, body) in [("chinese", "惯习"), ("english", "habitus"), ("alias", "习性")] {
            try "---\ntype: note\ntitle: \(name)\n---\n\(body)".write(
                to: root.appendingPathComponent("vault/\(name).md"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sources"), withIntermediateDirectories: true)
        let indexer = VaultIndexer(workspaceRoot: root.path)
        try await indexer.reconcile()
        let client = LocalVaultClient(workspaceRoot: root.path,
            index: IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path))
        let defaults = UserDefaults(suiteName: "search-tests-\(UUID().uuidString)")!
        if enableExpansion {
            defaults.set(true, forKey: SettingsKeys.balancedTermExpansion)
            defaults.set(true, forKey: SettingsKeys.deepTermExpansion)
        }
        let semantic = RecordingSemantic()
        let model = AppModel(client: client, semantic: semantic, workspaceRoot: root.path, searchDefaults: defaults)
        model.termIndexController = TermIndexController(workspaceRoot: root.path)
        try await model.termIndexController!.refresh()
        await model.loadIndex()
        return (root, model, defaults, semantic)
    }

    @Test func unverifiedExpansionIsOffByDefault() async throws {
        let (root, model, defaults, semantic) = try await fixture(enableExpansion: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(defaults.object(forKey: SettingsKeys.balancedTermExpansion) == nil)
        #expect(defaults.object(forKey: SettingsKeys.deepTermExpansion) == nil)
        let hits = await model.commandSearch("惯习", mode: .balanced)
        #expect(hits.contains { $0.entry.path == "vault/chinese.md" })
        #expect(!hits.contains { $0.entry.path == "vault/english.md" || $0.entry.path == "vault/alias.md" })
        _ = await model.commandSearch("惯习", mode: .deep)
        #expect(await semantic.queries == ["惯习"])
    }

    @Test func independentSwitchesReachRealFTSAndSemanticBackend() async throws {
        let (root, model, defaults, semantic) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(false, forKey: SettingsKeys.balancedTermExpansion)
        defaults.set(true, forKey: SettingsKeys.deepTermExpansion)
        let direct = await model.commandSearch("惯习", mode: .balanced)
        #expect(direct.contains { $0.entry.path == "vault/chinese.md" })
        #expect(!direct.contains { $0.entry.path == "vault/english.md" })
        let deep = await model.commandSearch("惯习", mode: .deep)
        #expect(await semantic.queries == ["惯习", "habitus", "习性"])
        #expect(Set(deep.map(\.entry.path)) == ["vault/chinese.md", "vault/english.md", "vault/alias.md"])

        defaults.set(true, forKey: SettingsKeys.balancedTermExpansion)
        defaults.set(false, forKey: SettingsKeys.deepTermExpansion)
        let expanded = await model.commandSearch("惯习", mode: .balanced)
        #expect(expanded.contains { $0.entry.path == "vault/english.md" })
        #expect(expanded.contains { $0.entry.path == "vault/alias.md" })
        #expect(Set(expanded.map(\.entry.path)).count == expanded.count)
        await semantic.clear()
        _ = await model.commandSearch("惯习", mode: .deep)
        #expect(await semantic.queries == ["惯习"])

        defaults.set(1, forKey: SettingsKeys.termExpansionDepth)
        let oneHop = await model.commandSearch("惯习", mode: .balanced)
        #expect(!oneHop.contains { $0.entry.path == "vault/alias.md" })
        let fast = await model.commandSearch("惯习", mode: .fast)
        #expect(!fast.contains { $0.entry.path == "vault/english.md" })
    }

    @Test func viewAllKeepsResultsAndModeWithoutSearchingAgain() async throws {
        let (root, model, _, semantic) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let results = await model.commandSearch("惯习", mode: .deep)
        await semantic.clear()
        model.paletteViewAll(type: .note, query: "惯习", mode: .deep, results: results)
        #expect(model.visibleEntries.map(\.path) == results.map(\.entry.path))
        #expect(model.listSearchMode == .deep)
        #expect(await semantic.queries.isEmpty)
        await model.open("vault/chinese.md")
        #expect(model.workspace?.activeTab?.location.listContext?.searchMode == .deep)
        model.setSearchText("习性")
        #expect(model.isSearching)
        try await Task.sleep(for: .milliseconds(350))
        #expect(await semantic.queries.first == "习性")
        #expect(model.listSearchMode == .deep)
        #expect(!model.isSearching)
    }

    @Test func cancellationStopsRemainingExpandedQueries() async throws {
        let (root, model, _, semantic) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await semantic.setDelay()
        let search = Task { await model.commandSearch("惯习", mode: .deep) }
        while await semantic.queries.isEmpty { await Task.yield() }
        search.cancel()
        #expect(await search.value.isEmpty)
        #expect(await semantic.queries == ["惯习"])
    }

    @Test func listContextReadsOldSessionsAndRoundTripsMode() throws {
        let context = ListContext(searchText: "惯习", filters: [], filterMatch: .all, sorts: [], searchMode: .deep)
        let data = try JSONEncoder().encode(context)
        #expect(try JSONDecoder().decode(ListContext.self, from: data) == context)
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "searchMode")
        #expect(try JSONDecoder().decode(ListContext.self, from: JSONSerialization.data(withJSONObject: old)).searchMode == .balanced)
    }
}

private actor RecordingSemantic: SemanticBackend {
    var queries: [String] = []
    var delayed = false
    func clear() { queries = [] }
    func setDelay() { delayed = true }
    func search(_ query: String, topK: Int) async throws -> [(path: String, score: Double)] {
        queries.append(query)
        if delayed { try await Task.sleep(for: .seconds(10)) }
        let names = ["惯习": "chinese", "habitus": "english", "习性": "alias"]
        return names[query].map { [(path: "vault/\($0).md", score: 0.8)] } ?? []
    }
}

/// Reads existing indexes only. Enable explicitly for local GPU/latency checks.
@Suite struct ExpandedSearchCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_SEARCH_TERMS_DB"] != nil))
    func frequencyFilteredQueries() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MARPLE_SEARCH_TERMS_DB"])
        let index = TermIndex(workspaceRoot: FileManager.default.temporaryDirectory.path, databasePath: path)
        for term in ["能动性", "具身性", "惯习", "异化", "社会资本", "文化资本", "象征资本", "象征暴力",
            "场域", "可供性", "主体性", "物质性", "认同", "情感", "权力"] {
            let start = Date()
            let firstHop = try await index.expandedQueries(term, depth: 1)
            let queries = try await index.expandedQueries(term, depth: 2)
            #expect(queries.first == term)
            #expect(Set(queries).count == queries.count)
            #expect(queries.count <= 31)
            print("FREQUENCY_CORPUS term=\(term) count=\(queries.count) seconds=\(Date().timeIntervalSince(start)) first_hop=\(firstHop) queries=\(queries)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_SEARCH_CORPUS"] != nil))
    func realSemanticQueries() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = try #require(env["MARPLE_SEARCH_CORPUS"])
        let termsPath = try #require(env["MARPLE_SEARCH_TERMS_DB"])
        let term = env["MARPLE_SEARCH_QUERY"] ?? "具身性"
        let index = TermIndex(workspaceRoot: root, databasePath: termsPath)
        let start = Date()
        let queries = try await index.expandedQueries(term, depth: 2)
        print("EXPANSION_CORPUS term=\(term) queries=\(queries.count) expansion_seconds=\(Date().timeIntervalSince(start))")
        #expect(queries.first == term && queries.count > 1)
        let backend = MLXSemanticBackend(dir: URL(fileURLWithPath: root).appendingPathComponent(".marple"))
        var paths = Set<String>()
        var original = Set<String>()
        for (i, query) in queries.enumerated() {
            let before = Date()
            let hits = try await backend.search(query, topK: 80)
            paths.formUnion(hits.map(\.path))
            if i == 0 { original = paths }
            print("EXPANSION_CORPUS query=\(i + 1)/\(queries.count) hits=\(hits.count) seconds=\(Date().timeIntervalSince(before))")
        }
        #expect(original.isSubset(of: paths))
        print("EXPANSION_CORPUS original=\(original.count) expanded=\(paths.count) total_seconds=\(Date().timeIntervalSince(start))")
    }
}
