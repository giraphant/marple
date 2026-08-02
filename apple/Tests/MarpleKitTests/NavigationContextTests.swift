import Foundation
import AppKit
import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct NavigationContextTests {
    @MainActor
    @Test func temporaryTabRestoresCompleteListContext() async throws {
        let author = entry("authors/clare.md", type: .author, year: "2024")
        let book = entry("books/habit.md", type: .book, year: "2018")
        let authorFilter = FilterClause(
            id: "recent", field: .year, op: .gte, value: "2020")
        let authorSort = [SortClause(field: .title, dir: .desc)]
        let client = StubVaultClient(
            entries: [author, book],
            texts: [author.path: "# Clare", book.path: "# Habit"],
            hits: [SearchHit(entry: author, score: 1, snippet: nil, source: "test")])
        let model = AppModel(client: client)
        await model.loadIndex()

        model.select(pane: .type(.author))
        await model.open(author.path)
        let authorTab = try #require(model.activeTabID)
        model.setFilters([authorFilter], match: .any)
        model.setSort(authorSort)
        model.setSearchText("clare")
        await waitForEntries([author.path], in: model)

        model.select(pane: .type(.book))
        model.setFilters([], match: .all)
        model.setSort([SortClause(field: .year, dir: .asc)])
        model.setSearchText("")
        await model.open(book.path)
        await model.selectTab(authorTab)
        await waitForEntries([author.path], in: model)

        #expect(model.pane == .type(.author))
        #expect(model.searchText == "clare")
        #expect(model.activeFilterClauses == [authorFilter])
        #expect(model.activeFilterMatch == .any)
        #expect(model.activeSortClauses == authorSort)
        #expect(model.openPath == author.path)
        #expect(model.visibleEntries.map(\.path) == [author.path])
    }

    @MainActor
    @Test func legacyTemporaryTabReconstructsRevealableListContext() async throws {
        let book = entry("books/context.md", type: .book, year: "2025")
        let chapter = entry("books/context/ch01.md", type: .chapter, year: "1997")
        let sort = [SortClause(field: .title, dir: .desc)]
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        store.save(PersistedState(
            browsePane: .type(.book),
            isBrowsing: false,
            tabs: [
                PersistedTab(
                    location: NavLocation(pane: .type(.book), openPath: book.path),
                    pinned: false,
                    cachedType: .book),
                PersistedTab(
                    location: NavLocation(pane: .type(.book), openPath: chapter.path),
                    pinned: false,
                    cachedType: .chapter),
            ],
            activeIndex: 0,
            sortClauses: sort,
            filterClauses: [FilterClause(field: .year, op: .gte, value: "2020")],
            filterMatch: .all,
            browseMode: "list"))
        let model = AppModel(
            client: StubVaultClient(
                entries: [book, chapter],
                texts: [book.path: "# Context", chapter.path: "# Chapter"]),
            stateStore: store)
        await model.loadIndex()

        let chapterTab = try #require(model.tabs.first {
            $0.location.openPath == chapter.path
        })
        await model.selectTab(chapterTab.id)
        await waitForEntries([chapter.path], in: model)

        #expect(model.pane == .type(.chapter))
        #expect(model.searchText.isEmpty)
        #expect(model.activeFilterClauses.isEmpty)
        #expect(model.activeSortClauses == sort)
        #expect(model.tabs.first { $0.id == chapterTab.id }?.location.listContext
            == ListContext(searchText: "", filters: [], filterMatch: .all, sorts: sort))
    }

    @MainActor
    @Test func activeLegacyTemporaryTabReconstructsContextAfterIndexLoad() async throws {
        let chapter = entry("books/context/ch01.md", type: .chapter, year: "1997")
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        store.save(PersistedState(
            browsePane: .type(.book),
            isBrowsing: false,
            tabs: [PersistedTab(
                location: NavLocation(pane: .type(.book), openPath: chapter.path),
                pinned: false)],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [FilterClause(field: .year, op: .gte, value: "2020")],
            filterMatch: .all,
            browseMode: "list"))
        let model = AppModel(
            client: StubVaultClient(
                entries: [chapter], texts: [chapter.path: "# Chapter"]),
            stateStore: store)

        await model.loadIndex()
        await waitForEntries([chapter.path], in: model)

        #expect(model.pane == .type(.chapter))
        #expect(model.activeFilterClauses.isEmpty)
        #expect(model.tabs.first?.location.listContext
            == ListContext(searchText: "", filters: [], filterMatch: .all, sorts: []))
    }

    @MainActor
    @Test func legacySavedViewTabKeepsSavedViewIdentity() async throws {
        let paper = entry("papers/context.md", type: .paper, year: "2025")
        let view = SavedView(
            name: "Recent papers",
            clauses: [FilterClause(field: .year, op: .gte, value: "2020")],
            match: .all,
            sorts: [SortClause(field: .year, dir: .desc)])
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        var state = PersistedState(
            browsePane: .savedView(view.id),
            isBrowsing: false,
            tabs: [PersistedTab(
                location: NavLocation(pane: .savedView(view.id), openPath: paper.path),
                pinned: false,
                cachedType: .paper)],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "list")
        state.savedViews = [view]
        store.save(state)
        let model = AppModel(
            client: StubVaultClient(
                entries: [paper], texts: [paper.path: "# Context"]),
            stateStore: store)

        await model.loadIndex()
        await waitForEntries([paper.path], in: model)

        #expect(model.pane == .savedView(view.id))
        #expect(model.activeFilterClauses == view.clauses)
        #expect(model.activeSortClauses == view.sorts)
        #expect(model.tabs.first?.location.listContext != nil)
    }

    @MainActor
    @Test func commandPaletteResultUsesCleanObjectTypeContext() async throws {
        let book = entry("books/context.md", type: .book, year: "2025")
        let author = entry("authors/agre.md", type: .author, year: "1997")
        let sort = [SortClause(field: .title, dir: .desc)]
        let model = AppModel(client: StubVaultClient(
            entries: [book, author],
            texts: [book.path: "# Context", author.path: "# Agre"],
            hits: [SearchHit(entry: book, score: 1, snippet: nil, source: "test")]))
        await model.loadIndex()

        model.select(pane: .type(.book))
        model.setFilters([FilterClause(field: .year, op: .gte, value: "2020")])
        model.setSort(sort)
        model.setSearchText("context")
        await waitForEntries([book.path], in: model)
        await model.open(book.path)

        await model.openFromPalette(author)

        #expect(model.pane == .type(.author))
        #expect(model.searchText.isEmpty)
        #expect(model.activeFilterClauses.isEmpty)
        #expect(model.activeSortClauses == sort)
        #expect(model.openPath == author.path)
        await waitForEntries([author.path], in: model)
        #expect(model.tabs.first { $0.location.openPath == author.path }?.location.listContext
            == ListContext(searchText: "", filters: [], filterMatch: .all, sorts: sort))
    }

    @MainActor
    @Test func savedViewTabUsesTheLatestSharedDefinition() async throws {
        let oldPaper = entry("papers/old.md", type: .paper, year: "1999")
        let newPaper = entry("papers/new.md", type: .paper, year: "2025")
        let book = entry("books/context.md", type: .book, year: "2022")
        let model = AppModel(client: StubVaultClient(
            entries: [oldPaper, newPaper, book],
            texts: [oldPaper.path: "# Old", newPaper.path: "# New",
                    book.path: "# Context"]))
        await model.loadIndex()

        model.select(pane: .type(.paper))
        model.setFilters([FilterClause(id: "old", field: .year, op: .lte, value: "2000")])
        let viewID = model.createSavedView(named: "论文视图").id
        await model.open(oldPaper.path)
        let viewTab = try #require(model.activeTabID)

        model.select(pane: .savedView(viewID))
        let latest = [
            FilterClause(id: "paper", field: .type, op: .is_, value: EntryType.paper.rawValue),
            FilterClause(id: "new", field: .year, op: .gte, value: "2020"),
        ]
        let latestSort = [SortClause(field: .year, dir: .desc)]
        model.setFilters(latest, match: .all)
        model.setSort(latestSort)
        model.select(pane: .type(.book))
        await model.open(book.path)
        await model.selectTab(viewTab)
        await waitForEntries([newPaper.path], in: model)

        #expect(model.pane == .savedView(viewID))
        #expect(model.activeFilterClauses == latest)
        #expect(model.activeSortClauses == latestSort)
        #expect(model.visibleEntries.map(\.path) == [newPaper.path])
    }

    @MainActor
    @Test func pinnedTabsShareTheirListAndUnpinReturnsToBrowseContext() async throws {
        let author = entry("authors/clare.md", type: .author)
        let paper = entry("papers/agency.md", type: .paper)
        let client = StubVaultClient(
            entries: [paper, author],
            texts: [author.path: "# Clare", paper.path: "# Agency"],
            hits: [SearchHit(entry: paper, score: 1, snippet: nil, source: "test")])
        let model = AppModel(client: client)
        await model.loadIndex()

        model.select(pane: .type(.paper))
        model.setSearchText("agency")
        await waitForEntries([paper.path], in: model)
        await model.open(paper.path)
        let paperTab = try #require(model.activeTabID)
        model.togglePin(paperTab)
        #expect(model.isPinnedListContext)
        #expect(model.visibleEntries.map(\.path) == [paper.path])

        await model.openInNewTab(author.path)
        let authorTab = try #require(model.activeTabID)
        #expect(!model.isPinnedListContext)
        #expect(model.searchText == "agency")
        model.togglePin(authorTab)
        #expect(model.visibleEntries.map(\.path) == [paper.path, author.path])

        model.setSearchText("pinned search")
        await waitForEntries([paper.path], in: model)
        await model.selectTab(paperTab)
        #expect(model.searchText == "pinned search")
        #expect(model.visibleEntries.map(\.path) == [paper.path])
        #expect(model.activeTabID == paperTab)

        model.togglePin(paperTab)
        await waitForEntries([paper.path], in: model)

        #expect(!model.isPinnedListContext)
        #expect(model.pane == .type(.paper))
        #expect(model.searchText == "agency")
        #expect(model.openPath == paper.path)
        #expect(model.visibleEntries.map(\.path) == [paper.path])
    }

    @MainActor
    @Test func newTemporaryTabDoesNotInheritPinnedListSearch() async throws {
        let author = entry("authors/clare.md", type: .author)
        let paper = entry("papers/agency.md", type: .paper)
        let client = StubVaultClient(
            entries: [author, paper],
            texts: [author.path: "# Clare", paper.path: "# Agency"],
            hits: [SearchHit(entry: author, score: 1, snippet: nil, source: "test")])
        let model = AppModel(client: client)
        await model.loadIndex()

        model.select(pane: .type(.author))
        await model.open(author.path)
        let pinnedID = try #require(model.activeTabID)
        model.togglePin(pinnedID)
        model.setSearchText("pinned search")
        await waitForEntries([author.path], in: model)
        await model.openInNewTab(paper.path)

        #expect(!model.isPinnedListContext)
        #expect(model.pane == .type(.author))
        #expect(model.searchText.isEmpty)
        #expect(model.openPath == paper.path)

        await model.selectTab(pinnedID)
        await waitForEntries([author.path], in: model)
        #expect(model.isPinnedListContext)
        #expect(model.searchText == "pinned search")
    }

    @MainActor
    @Test func unpinningLiftsATabOutOfItsFolder() async throws {
        let first = entry("papers/first.md", type: .paper)
        let second = entry("papers/second.md", type: .paper)
        let model = AppModel(client: StubVaultClient(
            entries: [first, second], texts: [first.path: "# First", second.path: "# Second"]))
        await model.loadIndex()

        await model.open(first.path)
        let firstID = try #require(model.activeTabID)
        model.togglePin(firstID)
        model.select(pane: .type(.paper))
        await model.open(second.path)
        let secondID = try #require(model.activeTabID)
        model.togglePin(secondID)
        model.groupTab(secondID, onto: firstID)
        #expect(model.tabGroups.count == 1)

        model.togglePin(secondID)

        #expect(model.tabGroups.isEmpty)
        #expect(model.tabGroup(containing: secondID) == nil)
        #expect(model.pinnedTabRootNodes == [.tab(firstID)])
        #expect(model.temporaryTabs.map(\.id) == [secondID])
        #expect(model.tabs.filter(\.pinned).map(\.id) == [firstID])
        #expect(model.tabs.filter { !$0.pinned }.map(\.id) == [secondID])
    }

    @MainActor
    @Test func browsingSpaceClearsPreviousPinnedListContext() async throws {
        let author = entry("authors/clare.md", type: .author)
        let paper = entry("papers/agency.md", type: .paper)
        let client = StubVaultClient(
            entries: [author, paper],
            texts: [author.path: "# Clare", paper.path: "# Agency"],
            hits: [SearchHit(entry: paper, score: 1, snippet: nil, source: "test")])
        let model = AppModel(client: client)
        await model.loadIndex()

        model.select(pane: .type(.author))
        await model.open(author.path)
        model.togglePin(try #require(model.activeTabID))
        let pinnedSpace = try #require(model.activeSpaceID)
        model.setSearchText("pinned search")

        model.addSpace()
        let browsingSpace = try #require(model.activeSpaceID)
        await waitForEntries([author.path], in: model)
        #expect(model.isBrowsing)
        #expect(model.searchText.isEmpty)

        await model.selectSpace(pinnedSpace)
        model.setSearchText("another pinned search")
        await model.selectSpace(browsingSpace)
        await waitForEntries([author.path], in: model)
        #expect(model.isBrowsing)
        #expect(model.searchText.isEmpty)
    }

    @MainActor
    @Test func staleDocumentLoadCannotReplaceTheCurrentDocument() async throws {
        let slow = entry("papers/slow.md", type: .paper)
        let fast = entry("papers/fast.md", type: .paper)
        let gate = DocLoadGate()
        let client = GatedVaultClient(
            base: StubVaultClient(
                entries: [slow, fast],
                texts: [slow.path: "# Slow", fast.path: "# Fast"]),
            blockedPath: slow.path,
            gate: gate)
        let model = AppModel(client: client)
        await model.loadIndex()

        let slowOpen = Task { await model.open(slow.path) }
        await gate.waitUntilBlocked()
        await model.open(fast.path)
        await gate.release()
        await slowOpen.value

        #expect(model.openPath == fast.path)
        #expect(model.openBody == "# Fast")
        #expect(model.openEntry?.path == fast.path)
    }

    @MainActor
    @Test func pinnedTabNavigationKeepsItsAnchorInThePinnedListAndTitle() async throws {
        let book = entry("books/freedom.md", type: .book, year: "1999")
        let chapter = entry("books/freedom/ch04.md", type: .chapter, year: "1999")
        let model = AppModel(client: StubVaultClient(
            entries: [book, chapter],
            texts: [book.path: "# Freedom", chapter.path: "# Chapter 4"]))
        await model.loadIndex()
        await model.open(book.path)
        let id = try #require(model.activeTabID)
        model.togglePin(id)

        await model.open(chapter.path)

        let tab = try #require(model.tabs.first { $0.id == id })
        #expect(model.openPath == chapter.path)
        #expect(model.tabTitle(tab) == book.title)
        #expect(model.visibleEntries.map(\.path) == [book.path])
    }

    @MainActor
    @Test func closeActiveTabWithdrawsPinnedExcursionWithoutClosingPage() async throws {
        let book = entry("books/freedom.md", type: .book, year: "1999")
        let chapter = entry("books/freedom/ch04.md", type: .chapter, year: "1999")
        let model = AppModel(client: StubVaultClient(
            entries: [book, chapter],
            texts: [book.path: "# Freedom", chapter.path: "# Chapter 4"]))
        await model.loadIndex()
        await model.open(book.path)
        let id = try #require(model.activeTabID)
        model.togglePin(id)
        await model.open(chapter.path)

        await model.closeActiveTab()

        #expect(model.tabs.map(\.id) == [id])
        #expect(model.tabs.first?.pinned == true)
        #expect(model.openPath == book.path)
        #expect(model.tabs.first?.history.entries.map(\.openPath) == [book.path])

        let history = try #require(model.tabs.first?.history)
        await model.closeActiveTab()
        #expect(model.tabs.first?.history == history)
    }

    @MainActor
    @Test func pinnedTabExcursionDoesNotReloadItsAnchoredSidebarRow() async throws {
        let book = entry("books/freedom.md", type: .book)
        let chapter = entry("books/freedom/ch04.md", type: .chapter)
        let model = AppModel(client: StubVaultClient(
            entries: [book, chapter],
            texts: [book.path: "# Freedom", chapter.path: "# Chapter 4"]))
        await model.loadIndex()
        await model.open(book.path)
        model.togglePin(try #require(model.activeTabID))

        let coordinator = SidebarOutlineView.Coordinator(model: model)
        let outline = ReloadCountingOutlineView()
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.reload(outline)
        let reloads = outline.reloadDataCount

        await model.open(chapter.path)
        coordinator.reload(outline)

        #expect(outline.reloadDataCount == reloads)
    }

    @MainActor
    @Test func activatingPinnedAnchorSelectsItsLiveExcursion() async throws {
        let bookA = entry("books/a.md", type: .book)
        let chapterA = entry("books/a/ch04.md", type: .chapter)
        let bookB = entry("books/b.md", type: .book)
        let model = AppModel(client: StubVaultClient(
            entries: [bookA, chapterA, bookB],
            texts: [bookA.path: "# A", chapterA.path: "# A4", bookB.path: "# B"]))
        await model.loadIndex()
        await model.open(bookA.path)
        let tabA = try #require(model.activeTabID)
        model.togglePin(tabA)
        await model.open(chapterA.path)

        model.select(pane: .type(.book))
        await model.open(bookB.path)
        let tabB = try #require(model.activeTabID)
        model.togglePin(tabB)

        await model.activateVisibleEntry(bookA.path)

        #expect(model.activeTabID == tabA)
        #expect(model.openPath == chapterA.path)
    }

    private func entry(_ path: String, type: EntryType,
                       year: String? = nil, hasPDF: Bool = false) -> Entry {
        Entry(path: path, type: type, title: path, author: [], year: year,
              ratingScore: 0, themes: [], preview: "", hasPDF: hasPDF)
    }

    @MainActor
    private func waitForEntries(_ paths: [String], in model: AppModel) async {
        for _ in 0..<50 {
            if model.visibleEntries.map(\.path) == paths { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for entries: \(paths)")
    }
}

private actor DocLoadGate {
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        blocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct GatedVaultClient: VaultClient {
    let base: StubVaultClient
    let blockedPath: String
    let gate: DocLoadGate

    func index() async throws -> [Entry] { try await base.index() }
    func entryText(path: String) async throws -> String {
        if path == blockedPath { await gate.block() }
        return try await base.entryText(path: path)
    }
    func search(_ query: SearchQuery) async throws -> [SearchHit] { try await base.search(query) }
    func openInEditor(path: String, app: String) async throws { try await base.openInEditor(path: path, app: app) }
    func openPDF(slug: String) async throws { try await base.openPDF(slug: slug) }
    func openTranslation(slug: String) async throws { try await base.openTranslation(slug: slug) }
    func hasTranslation(slug: String) -> Bool { base.hasTranslation(slug: slug) }
    func imageOriginalURL(forImageEntryPath path: String) async throws -> URL? {
        try await base.imageOriginalURL(forImageEntryPath: path)
    }
    func fileURL(for path: String) -> URL? { base.fileURL(for: path) }
    func createImageObject(from sourceURL: URL, title: String?) async throws -> Entry {
        try await base.createImageObject(from: sourceURL, title: title)
    }
    func writeFile(path: String, text: String) async throws { try await base.writeFile(path: path, text: text) }
    func createNote(path: String, text: String) async throws { try await base.createNote(path: path, text: text) }
    func moveToTrash(path: String) async throws -> String { try await base.moveToTrash(path: path) }
    func listTrash() async throws -> [TrashItem] { try await base.listTrash() }
    func restoreTrash(name: String) async throws -> String { try await base.restoreTrash(name: name) }
    func purgeTrash(name: String) async throws { try await base.purgeTrash(name: name) }
}

private final class ReloadCountingOutlineView: NSOutlineView {
    private(set) var reloadDataCount = 0

    override func reloadData() {
        reloadDataCount += 1
        super.reloadData()
    }
}
