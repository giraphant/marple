import AppKit
import Foundation
import GRDB
import Testing
@testable import Marple
@testable import MarpleKit

/// Opt-in measurements, separate from correctness tests: run in release mode.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_BENCH"] == "1"))
@MainActor struct PerformanceBenchmarkTests {
    @Test
    func reconcileBatchDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marple-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("vault"), withIntermediateDirectories: true)
        let indexPath = root.appendingPathComponent("index.sqlite").path
        let indexer = VaultIndexer(workspaceRoot: root.path, indexDBPath: indexPath)
        let queue = try DatabaseQueue(path: indexPath)
        let text = String(repeating: "Markdown preview 中文索引 performance. ", count: 1000)
        var samples: [Double] = []
        for _ in 0..<3 {
            try queue.write { db in
                try IndexWriter.createSchema(db)
                for i in 0..<600 {
                    let path = "vault/removed-\(i).md"
                    try db.execute(sql: "INSERT INTO entries (path, type, mtime) VALUES (?, 'paper', 0)", arguments: [path])
                    try db.execute(sql: "INSERT INTO entry_trigram (path, type, text) VALUES (?, 'paper', ?)", arguments: [path, text])
                }
            }
            let start = ContinuousClock.now
            let stats = try indexer.reconcile()
            samples.append(milliseconds(start.duration(to: .now)))
            #expect(stats == ReconcileStats(removed: 600))
            let remaining = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry_trigram") }
            #expect(remaining == 0)
        }
        report("reconcile delete 600 entries / \(600 * text.utf8.count) text bytes", samples: samples)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_STATE"] != nil))
    func savedSessionEncodingComponents() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_STATE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        var encoded = Data()
        try measure("full session encoding") { encoded = try JSONEncoder().encode(state) }
        #expect(try JSONDecoder().decode(PersistedState.self, from: encoded) == state)
        print("[performance] full session bytes: \(encoded.count)")
        var unique = state
        unique.tabs = []
        unique.currentSpace = nil
        try measure("session encoding without legacy mirrors, research only") {
            encoded = try JSONEncoder().encode(unique)
        }
        #expect(try JSONDecoder().decode(PersistedState.self, from: encoded) == unique)
        print("[performance] session without mirrors bytes: \(encoded.count)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_STATE"] != nil))
    func savedSessionNavigation() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["MARPLE_PERFORMANCE_STATE"])
        let root = try #require(environment["MARPLE_PERFORMANCE_VAULT"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        let spaces = try #require(state.spaces)
        let paths = Set(spaces.flatMap { $0.tabs.compactMap { $0.location.openPath } })
        let corpus = try IndexDatabase(indexDBPath: root + "/.marple/index.sqlite").loadEntries()
        let indexedPaths = Set(corpus.map(\.path))
        print("[performance] saved session: \(spaces.count) spaces, \(spaces.reduce(0) { $0 + $1.tabs.count }) tabs, \(paths.count) unique paths, \(paths.subtracting(indexedPaths).count) absent from index")

        var decoded: PersistedState?
        try measure("saved session JSON decode") {
            decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        }
        #expect(decoded == state)
        var encoded = Data()
        try measure("saved session JSON encode") { encoded = try JSONEncoder().encode(state) }
        #expect(try JSONDecoder().decode(PersistedState.self, from: encoded) == state)

        // Real tab state and index, fixed short bodies: isolate navigation/state
        // costs from file downloads, Markdown rendering and on-screen layout.
        let texts = Dictionary(uniqueKeysWithValues: paths.map { ($0, "# Benchmark\n\nShort document.") })
        let suite = "marple-session-performance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let store = UserDefaultsStateStore(defaults: defaults)
        measure("saved session UserDefaults save") { store.save(state) }
        let start = ContinuousClock.now
        let model = AppModel(client: StubVaultClient(entries: corpus, texts: texts),
                             stateStore: store, workspaceRoot: temporaryRoot.path)
        report("saved session model restore", samples: [milliseconds(start.duration(to: .now))])
        #expect(model.spaces.map { $0.workspace?.tabs.count ?? 0 } == spaces.map { $0.tabs.count })
        await model.loadIndex()
        await model.catalog.deferredDerivedTask?.value
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let restored = try #require(store.load()?.spaces)
        let visible = model.spaces.filter { !$0.isArchived && ($0.workspace?.tabs.count ?? 0) >= 2 }
        try #require(visible.count >= 2)
        // Exercise the production AppKit sidebar without opening a window or
        // installing the fixture into the user's running application.
        let coordinator: SidebarOutlineView.Coordinator = {
            let defaults = UserDefaults.standard
            let key = "marple.collapsedSidebarSections"
            let previous = defaults.object(forKey: key)
            print("[performance] prior collapsed sidebar sections: \(defaults.stringArray(forKey: key) ?? [])")
            defaults.set([], forKey: key)
            defer {
                if let previous { defaults.set(previous, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            return SidebarOutlineView.Coordinator(model: model)
        }()
        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.width = 280
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outlineView = outline
        coordinator.reload(outline)
        for (number, space) in visible.enumerated() {
            await model.selectSpace(space.id)
            coordinator.reload(outline)
            let count = model.tabs.count
            var samples: [Double] = []
            var sidebarSamples: [Double] = []
            for i in 0..<8 {
                let index = (i % 4) * (count - 1) / 3
                let start = ContinuousClock.now
                await model.selectTab(index: index)
                samples.append(milliseconds(start.duration(to: .now)))
                let sidebarStart = ContinuousClock.now
                coordinator.reload(outline)
                outline.layoutSubtreeIfNeeded()
                sidebarSamples.append(milliseconds(sidebarStart.duration(to: .now)))
                #expect(model.activeTabID == model.tabs[index].id)
                #expect(store.load()?.activeIndex == index)
            }
            report("saved session tab switch, space \(number), \(count) tabs", samples: Array(samples.dropFirst(2)))
            report("saved session sidebar tab update, \(count) tabs", samples: Array(sidebarSamples.dropFirst(2)))
        }
        var samples: [Double] = []
        var sidebarSamples: [Double] = []
        for i in 0..<(visible.count * 3) {
            let space = visible[i % visible.count]
            let start = ContinuousClock.now
            await model.selectSpace(space.id)
            samples.append(milliseconds(start.duration(to: .now)))
            let sidebarStart = ContinuousClock.now
            coordinator.reload(outline)
            outline.layoutSubtreeIfNeeded()
            sidebarSamples.append(milliseconds(sidebarStart.duration(to: .now)))
            #expect(model.activeSpaceID == space.id)
            #expect(store.load()?.activeSpaceID == space.id)
        }
        report("saved session space switch", samples: Array(samples.dropFirst(visible.count)))
        report("saved session sidebar space update", samples: Array(sidebarSamples.dropFirst(visible.count)))
        // Measure the middle column separately, with a viewport so AppKit only
        // materializes visible cards. This still excludes window painting.
        let listCoordinator = EntryListTable.Coordinator(model: model)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let listColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        listColumn.width = 300
        table.addTableColumn(listColumn)
        table.headerView = nil
        table.style = .inset
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.dataSource = listCoordinator
        table.delegate = listCoordinator
        listCoordinator.tableView = table
        let listScroll = NSScrollView(frame: table.frame)
        listScroll.hasVerticalScroller = true
        listScroll.documentView = table
        for space in visible {
            await model.selectSpace(space.id)
            guard let pinned = model.tabs.first(where: { $0.pinned }) else { continue }
            await model.selectTab(pinned.id)
            var list: [Entry] = []
            measure("saved session pinned list, \(model.tabs.count) tabs") { list = model.visibleEntries }
            #expect(!list.isEmpty)
            var tree: [TabNode] = []
            measure("saved session pinned tree, \(model.tabs.count) tabs") { tree = model.pinnedTabRootNodes }
            #expect(!tree.isEmpty)
            let pinnedTabs = model.tabs.filter(\.pinned)
            var listSamples: [Double] = []
            for i in 0..<6 {
                await model.selectTab(pinnedTabs[i.isMultiple(of: 2) ? 0 : pinnedTabs.count - 1].id)
                let start = ContinuousClock.now
                listCoordinator.reload(table)
                listScroll.layoutSubtreeIfNeeded()
                listSamples.append(milliseconds(start.duration(to: .now)))
                #expect(table.selectedRow >= 0)
            }
            report("saved session middle list update, \(model.tabs.count) tabs",
                   samples: Array(listSamples.dropFirst(2)))
        }
        // Repeat sidebar measurements with the same viewport as a real column.
        // Keep this after the historical segments so they remain comparable.
        let sidebarScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.documentView = outline
        outline.headerView = nil
        outline.indentationPerLevel = 14
        var viewportSamples: [Double] = []
        for i in 0..<(visible.count * 3) {
            await model.selectSpace(visible[i % visible.count].id)
            let start = ContinuousClock.now
            coordinator.reload(outline)
            sidebarScroll.layoutSubtreeIfNeeded()
            viewportSamples.append(milliseconds(start.duration(to: .now)))
            #expect(outline.selectedRow >= 0)
            #expect(outline.visibleRect.height <= 600)
        }
        report("saved session sidebar space viewport update", samples: Array(viewportSamples.dropFirst(visible.count)))
        let selectedTab = try #require(model.activeTabID)
        var browseSamples: [Double] = []
        for i in 0..<8 {
            model.select(pane: .type(i.isMultiple(of: 2) ? .paper : .book))
            let start = ContinuousClock.now
            coordinator.reload(outline)
            sidebarScroll.layoutSubtreeIfNeeded()
            browseSamples.append(milliseconds(start.duration(to: .now)))
            #expect(outline.selectedRow >= 0)
        }
        report("saved session browse sidebar viewport update", samples: Array(browseSamples.dropFirst(2)))
        await model.selectTab(selectedTab)
        let saved = try #require(store.load()?.spaces)
        #expect(saved.map(\.tabs) == restored.map(\.tabs))
        #expect(saved.map(\.tree) == restored.map(\.tree))
        #expect(saved.map(\.isArchived) == restored.map(\.isArchived))
        // Let the real debounced session writer finish in the temporary folder.
        try await Task.sleep(for: .seconds(2))
        let published = try JSONDecoder().decode(SessionSnapshot.self, from:
            Data(contentsOf: SessionFile.url(workspaceRoot: temporaryRoot.path)))
        #expect(published.spaces.map(\.id) == visible.map(\.id))
        #expect(published.spaces.map(\.activePath) == visible.map { space in
            saved.first { $0.id == space.id }.flatMap { $0.tabs[$0.activeIndex].location.openPath }
        })
    }

    @Test func navigationDataPaths() throws {
        let corpus: [Entry]
        if let root = ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_VAULT"] {
            corpus = try IndexDatabase(indexDBPath: root + "/.marple/index.sqlite").loadEntries()
        } else {
            corpus = makeSyntheticEntries(32_000)
        }
        try #require(corpus.count >= 4)
        let path = corpus[corpus.count / 2].path
        var found: Entry?
        measure("entry lookup, values") { found = corpus.first { $0.path == path } }
        #expect(found?.path == path)
        measure("entry lookup, indices") {
            found = corpus.indices.first { corpus[$0].path == path }.map { corpus[$0] }
        }
        #expect(found?.path == path)

        let openPaths = Set(stride(from: 0, to: corpus.count, by: corpus.count / 4).map { corpus[$0].path })
        var saved: [String: Entry] = [:]
        measure("tab metadata, values") {
            saved = Dictionary(corpus.lazy.filter { openPaths.contains($0.path) }.map { ($0.path, $0) },
                               uniquingKeysWith: { a, _ in a })
        }
        let expected = saved
        measure("tab metadata, indices") {
            saved = [:]
            for i in corpus.indices where openPaths.contains(corpus[i].path) {
                let entry = corpus[i]
                if saved[entry.path] == nil { saved[entry.path] = entry }
            }
        }
        #expect(saved == expected)

        let entry = try #require(corpus.first { $0.type == .paper && $0.themes.count >= 2 })
        let catalog = Catalog()
        catalog.entries = corpus
        catalog.relationGraph = RelationGraph.build(corpus)
        let body = "# Benchmark\n\nShort document."
        let blocks = MarkdownModel.blocks(from: body)
        measure("open-document derived state") {
            catalog.recomputeOpenDerived(openPath: entry.path, openBody: body, openBlocks: blocks)
        }
        #expect(catalog.openEntry?.path == entry.path)
        var related: Relations?
        measure("open-document relations") {
            related = relations(for: entry, in: corpus, graph: catalog.relationGraph)
        }
        #expect(related == catalog.openRelations)
        if let chapter = corpus.first(where: { $0.type == .chapter && !($0.book ?? "").isEmpty }) {
            var context: BookContext?
            measure("book context") { context = bookContext(for: chapter, in: corpus) }
            #expect(context?.chapters.contains { $0.path == chapter.path } == true)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_DOCUMENTS"] != nil))
    func realDocumentRendering() throws {
        let paths = try #require(ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_DOCUMENTS"])
        for path in paths.split(separator: "\n") {
            let url = URL(fileURLWithPath: String(path))
            let markdown = try String(contentsOf: url, encoding: .utf8)
            measure("real document render \(url.lastPathComponent)") {
                _ = MarkdownRenderer.render(markdown, style: RenderStyle(size: 17, fontFamily: nil, lineHeight: 1.5))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_DOCUMENTS"] != nil))
    func indexBodyProcessing() throws {
        let paths = try #require(ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_DOCUMENTS"])
        for (index, path) in paths.split(separator: "\n").enumerated() {
            let raw = try String(contentsOfFile: String(path), encoding: .utf8)
            let body = Frontmatter.split(raw).body
            let normalized = normalizeBodyForSearch(body)
            var preview = ""
            measure("index preview, sample \(index), \(body.utf8.count) bytes") {
                preview = firstParagraph(body)
            }
            #expect(preview.unicodeScalars.count <= 800)
            var searchable = ""
            measure("index search text, sample \(index)") {
                searchable = searchText(["vault/benchmark.md", "Benchmark", normalized])
            }
            #expect(searchable.hasPrefix("vault/benchmark.md\nBenchmark"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_PREFERENCES"] != nil))
    func productionReaderLayout() throws {
        let environment = ProcessInfo.processInfo.environment
        let preferencePath = try #require(environment["MARPLE_PERFORMANCE_PREFERENCES"])
        let preferences = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: preferencePath)), format: nil) as? [String: Any])
        let family = ReadingFontFamily(rawValue: preferences[SettingsKeys.readingFontFamily] as? String ?? "sans") ?? .sans
        let style = RenderStyle(
            size: preferences[SettingsKeys.readingFontSize] as? Double ?? ReadingDefaults.fontSize,
            fontFamily: family.systemFamily, bodyWeight: family.bodyWeight,
            letterSpacing: preferences[SettingsKeys.readingLetterSpacing] as? Double ?? ReadingDefaults.letterSpacing,
            lineHeight: preferences[SettingsKeys.readingLineHeight] as? Double ?? ReadingDefaults.lineHeight)
        print("[performance] reader requested family: \(family.systemFamily ?? "system"), resolved font: \(style.bodyFont.fontName), size: \(style.size), line height: \(style.lineHeight), tracking: \(style.letterSpacing)")
        let paths = try #require(environment["MARPLE_PERFORMANCE_DOCUMENTS"])
        for (index, path) in paths.split(separator: "\n").enumerated() {
            let raw = try String(contentsOfFile: String(path), encoding: .utf8)
            let body = Frontmatter.split(raw).body
            let markdown = Wikilink.preprocessForRendering(body)
            var rendered = MarkdownRenderer.render(markdown, style: style)
            measure("production reader render, sample \(index), \(raw.utf8.count) bytes") {
                rendered = MarkdownRenderer.render(markdown, style: style)
            }
            var layoutSamples: [Double] = []
            for iteration in 0..<4 {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = true
                let storage = NSTextStorage()
                let manager = NSLayoutManager()
                manager.allowsNonContiguousLayout = false
                let container = NSTextContainer(size: NSSize(width: Reading.measure, height: .greatestFiniteMagnitude))
                container.widthTracksTextView = false
                container.lineBreakMode = .byWordWrapping
                storage.addLayoutManager(manager)
                manager.addTextContainer(container)
                let reader = NSTextView(frame: .zero, textContainer: container)
                reader.isEditable = false
                reader.isVerticallyResizable = false
                reader.isHorizontallyResizable = false
                scroll.documentView = reader
                let start = ContinuousClock.now
                storage.setAttributedString(rendered.attributedString)
                MarkdownTextView.sizeDocumentView(in: scroll)
                layoutSamples.append(milliseconds(start.duration(to: .now)))
                #expect(manager.firstUnlaidCharacterIndex() == storage.length)
                #expect(reader.frame.height >= manager.usedRect(for: container).maxY)
                if iteration == 3 {
                    measure("production reader unchanged layout, sample \(index)") {
                        MarkdownTextView.sizeDocumentView(in: scroll)
                    }
                    print("[performance] production reader sample \(index): \(storage.length) UTF-16 units, height \(reader.frame.height)")
                }
            }
            report("production reader first layout, sample \(index)", samples: Array(layoutSamples.dropFirst()))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_VAULT"] != nil))
    func indexedSearchPaths() throws {
        let root = try #require(ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_VAULT"])
        let index = IndexDatabase(indexDBPath: root + "/.marple/index.sqlite")
        for query in ["machine learning", "身体", "身体 技术", "zzmarplebenchmarknomatchzz", ""] {
            let hits = try index.search(query, type: .paper, minRating: nil, theme: nil, limit: 100)
            print("[performance] indexed query \(query): \(hits.count) hits")
            try measure("indexed search \(query)") {
                _ = try index.search(query, type: .paper, minRating: nil, theme: nil, limit: 100)
            }
        }
    }

    @Test func interactivePaths() async throws {
        let corpus: [Entry]
        if let root = ProcessInfo.processInfo.environment["MARPLE_PERFORMANCE_VAULT"] {
            let index = IndexDatabase(indexDBPath: root + "/.marple/index.sqlite")
            corpus = try index.loadEntries()
            try measure("warm index read") { _ = try index.loadEntries() }
        } else {
            corpus = makeSyntheticEntries(32_000)
        }
        print("[performance] corpus: \(corpus.count) entries")
        #expect(!corpus.isEmpty)

        measure("relation graph") { _ = RelationGraph.build(corpus) }
        measure("search index") { _ = buildSearchIndex(corpus) }
        let search = buildSearchIndex(corpus)
        measure("fast search") { _ = searchDocuments(search, "machine learning") }
        measure("author lookup, missing") {
            _ = NameResolver.authorProfile(named: "Missing benchmark author", in: corpus)
        }
        let catalog = Catalog()
        measure("author index build") { catalog.entries = corpus }
        measure("catalog author lookup, missing") {
            _ = catalog.authorProfile(for: "Missing benchmark author")
        }
        measure("browse filter + sort") {
            _ = sortEntries(entriesForPane(.type(.paper), in: corpus), by: [])
        }

        let paragraph = "中文表格应保持现有换行和列宽，重复测量相同的字会增加切换成本。 "
        let markdown = "# Performance\n\n| Concept | Explanation |\n| --- | --- |\n"
            + (0..<20).map { "| Concept \($0) | \(String(repeating: paragraph, count: 8)) |" }.joined(separator: "\n")
        measure("markdown parse") { _ = MarkdownModel.blocks(from: markdown) }
        measure("markdown render, CJK table") {
            _ = MarkdownRenderer.render(markdown, style: RenderStyle(size: 17, fontFamily: nil, lineHeight: 1.5))
        }
        measure("document statistics") { _ = computeDocStats(markdown) }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let reader = NSTextView(frame: .zero)
        reader.isVerticallyResizable = false
        reader.textContainer?.widthTracksTextView = false
        reader.layoutManager?.allowsNonContiguousLayout = false
        reader.textStorage?.setAttributedString(MarkdownRenderer.render(
            markdown, style: RenderStyle(size: 17, fontFamily: nil, lineHeight: 1.5)).attributedString)
        scroll.documentView = reader
        measure("reader unchanged layout") { MarkdownTextView.sizeDocumentView(in: scroll) }

        let suite = "marple-performance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let docs = Array(corpus.prefix(2))
        try #require(docs.count == 2)
        let texts = Dictionary(uniqueKeysWithValues: docs.map { ($0.path, "# Benchmark\n\nShort document.") })
        let model = AppModel(client: StubVaultClient(entries: corpus, texts: texts),
                             stateStore: UserDefaultsStateStore(defaults: defaults))
        await model.loadIndex()
        await model.catalog.deferredDerivedTask?.value
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        for doc in docs { await model.openInNewTab(doc.path) }
        var samples: [Double] = []
        for i in 0..<8 {
            let start = ContinuousClock.now
            await model.selectTab(index: i % 2)
            samples.append(milliseconds(start.duration(to: .now)))
        }
        report("model tab switch", samples: Array(samples.dropFirst(2)))
        model.addSpace()
        await model.openInNewTab(docs[1].path)
        samples = []
        for i in 0..<8 {
            let start = ContinuousClock.now
            await model.selectSpace(model.spaces[i % 2].id)
            samples.append(milliseconds(start.duration(to: .now)))
        }
        report("model space switch", samples: Array(samples.dropFirst(2)))
    }

    private func measure(_ label: String, _ body: () throws -> Void) rethrows {
        try body()
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            try body()
            samples.append(milliseconds(start.duration(to: .now)))
        }
        report(label, samples: samples)
    }

    private func report(_ label: String, samples: [Double]) {
        let sorted = samples.sorted()
        print("[performance] \(label): median \(String(format: "%.2f", sorted[sorted.count / 2])) ms, max \(String(format: "%.2f", sorted.last!)) ms")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
