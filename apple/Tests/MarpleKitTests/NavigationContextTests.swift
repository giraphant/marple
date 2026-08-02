import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct NavigationContextTests {
    @MainActor
    @Test func temporaryTabsShareTheCurrentBrowseContext() async throws {
        let author = entry("authors/clare.md", type: .author)
        let book = entry("books/habit.md", type: .book)
        let client = StubVaultClient(
            entries: [author, book],
            texts: [author.path: "# Clare", book.path: "# Habit"],
            hits: [SearchHit(entry: book, score: 1, snippet: nil, source: "test")])
        let model = AppModel(client: client)
        await model.loadIndex()

        model.select(pane: .type(.author))
        await model.open(author.path)
        let authorTab = try #require(model.activeTabID)

        model.select(pane: .type(.book))
        model.setSearchText("habit")
        await waitForEntries([book.path], in: model)
        await model.open(book.path)
        await model.selectTab(authorTab)

        #expect(model.pane == .type(.book))
        #expect(model.searchText == "habit")
        #expect(model.openPath == author.path)
        #expect(model.visibleEntries.map(\.path) == [book.path])
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
