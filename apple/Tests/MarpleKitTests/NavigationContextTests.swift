import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct NavigationContextTests {
    @MainActor
    @Test func temporaryTabRestoresItsObjectContext() async throws {
        let author = entry("authors/clare.md", type: .author)
        let otherAuthor = entry("authors/archer.md", type: .author)
        let book = entry("books/habit.md", type: .book)
        let client = StubVaultClient(
            entries: [author, otherAuthor, book],
            texts: [author.path: "# Clare", otherAuthor.path: "# Archer", book.path: "# Habit"],
            hits: [SearchHit(entry: author, score: 1, snippet: nil, source: "test")])
        let model = AppModel(client: client)
        await model.loadIndex()

        model.select(pane: .type(.author))
        await model.open(author.path)
        let authorTab = try #require(model.activeTabID)
        model.setSearchText("clare")
        await waitForEntries([author.path], in: model)

        model.select(pane: .type(.book))
        await model.open(book.path)
        await model.selectTab(authorTab)
        await waitForEntries([author.path], in: model)

        #expect(model.pane == .type(.author))
        #expect(model.searchText == "clare")
        #expect(model.openPath == author.path)
        #expect(model.visibleEntries.map(\.path) == [author.path])
    }

    @MainActor
    @Test func pinnedListSelectsExistingTabAndUnpinRestoresObjectContext() async throws {
        let author = entry("authors/clare.md", type: .author)
        let paper = entry("papers/agency.md", type: .paper)
        let otherPaper = entry("papers/freedom.md", type: .paper)
        let book = entry("books/freedom.md", type: .book)
        let client = StubVaultClient(
            entries: [book, otherPaper, paper, author],
            texts: [author.path: "# Clare", paper.path: "# Agency",
                    otherPaper.path: "# Other", book.path: "# Freedom"],
            hits: [SearchHit(entry: paper, score: 1, snippet: nil, source: "test")])
        let model = AppModel(client: client)
        await model.loadIndex()

        model.select(pane: .type(.author))
        await model.open(author.path)
        let authorTab = try #require(model.activeTabID)
        model.togglePin(authorTab)
        #expect(model.isPinnedListContext)
        #expect(model.visibleEntries.map(\.path) == [author.path])

        model.select(pane: .type(.paper))
        model.setSearchText("agency")
        await model.open(paper.path)
        let paperTab = try #require(model.activeTabID)
        model.togglePin(paperTab)
        #expect(model.visibleEntries.map(\.path) == [author.path, paper.path])

        model.select(pane: .type(.book))
        await model.open(book.path)
        let bookTab = try #require(model.activeTabID)

        await model.selectTab(authorTab)
        let locations = model.tabs.map(\.location)

        #expect(model.isPinnedListContext)
        #expect(model.visibleEntries.map(\.path) == [author.path, paper.path])

        model.setSearchText("pinned search")
        await waitForEntries([paper.path], in: model)
        await model.closeTab(bookTab)
        #expect(model.searchText == "pinned search")
        #expect(model.visibleEntries.map(\.path) == [paper.path])

        await model.activateVisibleEntry(paper.path)

        #expect(model.activeTabID == paperTab)
        #expect(model.tabs.count == 2)
        #expect(model.tabs.map(\.location) == locations.filter { $0.openPath != book.path })
        #expect(model.visibleEntries.map(\.path) == [paper.path])

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
            hits: [SearchHit(entry: paper, score: 1, snippet: nil, source: "test")])
        let model = AppModel(client: client)
        await model.loadIndex()

        model.select(pane: .type(.author))
        await model.open(author.path)
        model.togglePin(try #require(model.activeTabID))
        model.setSearchText("pinned search")
        await model.selectNextTab()
        #expect(model.searchText == "pinned search")
        await model.openInNewTab(paper.path)

        #expect(!model.isPinnedListContext)
        #expect(model.pane == .type(.author))
        #expect(model.searchText.isEmpty)
        #expect(model.openPath == paper.path)
        #expect(model.tabs.last?.location.searchText == nil)
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

    private func entry(_ path: String, type: EntryType) -> Entry {
        Entry(path: path, type: type, title: path, author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
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
