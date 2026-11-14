import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

/// Two windows (`AppModel`s) over one `Library`: shared organization, independent
/// reading. See docs/multi-window-design.md §11.
@MainActor
@Suite struct MultiWindowTests {
    static let paths = ["vault/papers/a.md", "vault/papers/b.md", "vault/papers/c.md"]
    static let note = Entry(path: "vault/notes/n.md", type: .note, title: "N", author: [], year: nil,
                            ratingScore: 0, themes: [], preview: "", hasPDF: false,
                            annotates: "vault/papers/a.md")

    func makeLibrary(store: StateStore? = nil) -> Library {
        let entries = Self.paths.map { path in
            Entry(path: path, type: .paper, title: (path as NSString).lastPathComponent, author: [],
                  year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        } + [Self.note]
        var texts = Dictionary(uniqueKeysWithValues: Self.paths.map { ($0, "# \($0)") })
        texts[Self.note.path] = "---\ntype: note\n---\ndisk body"
        return Library(client: StubVaultClient(entries: entries, texts: texts), stateStore: store)
    }

    /// Window A with a pinned page on paths[0], and window B.
    func twoWindowsWithPinnedPage() async throws -> (Library, AppModel, AppModel, UUID) {
        let library = makeLibrary()
        let a = AppModel(library: library)
        await a.loadIndex()
        await a.openInNewTab(Self.paths[0])
        let pinned = try #require(a.activeTabID)
        a.togglePin(pinned)
        let b = AppModel(library: library)
        return (library, a, b, pinned)
    }

    @Test func windowsShareTheSpaceButReadIndependently() async throws {
        let library = makeLibrary()
        let a = AppModel(library: library)
        await a.loadIndex()
        let b = AppModel(library: library)
        #expect(b.activeSpaceID == a.activeSpaceID)

        await a.openInNewTab(Self.paths[0])
        await b.openInNewTab(Self.paths[1])
        #expect(a.openPath == Self.paths[0])
        #expect(b.openPath == Self.paths[1])
        #expect(a.tabs.map(\.location.openPath) == [Self.paths[0], Self.paths[1]])
        #expect(b.tabs.map(\.location.openPath) == [Self.paths[0], Self.paths[1]])

        a.setSearchText("needle")
        #expect(b.searchText == "")
        #expect(b.viewport !== a.viewport)
    }

    @Test func pinnedPageIsSharedWhileEachWindowKeepsItsOwnHistory() async throws {
        let (_, a, b, pinned) = try await twoWindowsWithPinnedPage()
        #expect(b.tabs.contains { $0.id == pinned && $0.pinned && $0.location.openPath == Self.paths[0] })

        await b.selectTab(pinned)
        await b.open(Self.paths[1])            // B follows a link inside the pinned page
        a.renameTab(pinned, to: "Alias")

        let bTab = try #require(b.tabs.first { $0.id == pinned })
        #expect(bTab.customTitle == "Alias")
        #expect(b.openPath == Self.paths[1])
        #expect(bTab.history.canGoBack)
        #expect(bTab.pinnedLocation?.openPath == Self.paths[0])
        #expect(a.tabs.first { $0.id == pinned }?.location.openPath == Self.paths[0])
    }

    @Test func unpinningKeepsWhatAnotherWindowIsReading() async throws {
        let (_, a, b, pinned) = try await twoWindowsWithPinnedPage()
        await b.selectTab(pinned)
        await b.open(Self.paths[1])

        a.togglePin(pinned)

        let kept = try #require(b.tabs.first { $0.id == pinned })
        #expect(!kept.pinned)
        #expect(b.activeTabID == kept.id)
        #expect(b.openPath == Self.paths[1])
    }

    @Test func temporaryTabChangesAreSharedButNavigationIsLocal() async throws {
        let library = makeLibrary()
        let a = AppModel(library: library)
        await a.loadIndex()
        let b = AppModel(library: library)
        await a.openInNewTab(Self.paths[0])
        let first = try #require(a.activeTabID)
        await b.selectTab(first)
        await b.open(Self.paths[1])
        #expect(a.openPath == Self.paths[0])
        #expect(b.openPath == Self.paths[1])
        #expect(b.canGoBack)

        await a.openInNewTab(Self.paths[2])
        let second = try #require(a.activeTabID)
        a.renameTab(second, to: "Shared")
        a.moveTabToRoot(second, beforeTab: first)
        #expect(b.tabs.map(\.id) == [second, first])
        #expect(b.tabs.first?.customTitle == "Shared")
        #expect(b.activeTabID == first)
        #expect(b.openPath == Self.paths[1])

        await a.closeTab(first)
        #expect(b.tabs.map(\.id) == [second])
        try await waitUntil { b.openPath == Self.paths[2] }
    }

    @Test func movingATabBetweenSpacesPreservesOtherWindowsHistory() async throws {
        let library = makeLibrary()
        let a = AppModel(library: library)
        await a.loadIndex()
        let b = AppModel(library: library)
        let source = try #require(a.activeSpaceID)
        await a.openInNewTab(Self.paths[0])
        let tab = try #require(a.activeTabID)
        await b.selectTab(tab)
        await b.open(Self.paths[1])
        a.addSpace()
        let destination = try #require(a.activeSpaceID)
        let undo = library.undoManager
        undo.groupsByEvent = false
        a.undoManager = undo
        undo.beginUndoGrouping()
        a.moveItems([.tab(tab)], from: source)
        undo.endUndoGrouping()

        await b.selectSpace(destination)
        await b.selectTab(tab)
        #expect(b.openPath == Self.paths[1])
        #expect(b.canGoBack)
        await b.goBack()
        #expect(b.openPath == Self.paths[0])
        undo.undo()
        await b.selectSpace(source)
        await b.selectTab(tab)
        #expect(b.openPath == Self.paths[0])
        #expect(b.canGoForward)
    }

    @Test func foldersAreSharedButCollapseIsPerWindow() async throws {
        let (_, a, b, pinned) = try await twoWindowsWithPinnedPage()
        await a.openInNewTab(Self.paths[1])
        let second = try #require(a.activeTabID)
        a.groupTabs([pinned, second])
        let folder = try #require(a.tabGroups.first?.id)
        #expect(b.tabGroups.map(\.id) == [folder])
        #expect(b.tabs(in: folder).map(\.id) == [pinned, second])

        a.setTabGroup(folder, collapsed: true)
        #expect(b.tabGroups.first?.isCollapsed == false)
        a.renameTabGroup(folder, to: "Reading")
        #expect(b.tabGroups.first?.name == "Reading")
        #expect(a.tabGroups.first?.isCollapsed == true)
    }

    @Test func organizationUndoIsSharedByEveryWindow() async throws {
        let (library, a, b, pinned) = try await twoWindowsWithPinnedPage()
        let undo = library.undoManager
        undo.groupsByEvent = false
        a.undoManager = undo
        b.undoManager = undo
        undo.beginUndoGrouping()
        a.renameTab(pinned, to: "Alias")
        undo.endUndoGrouping()
        #expect(b.tabs.first { $0.id == pinned }?.customTitle == "Alias")

        undo.undo()                              // ⌘Z pressed in window B
        #expect(a.tabs.first { $0.id == pinned }?.customTitle == nil)
        #expect(b.tabs.first { $0.id == pinned }?.customTitle == nil)
    }

    @Test func spaceChangesReachEveryWindow() async throws {
        let (_, a, b, pinned) = try await twoWindowsWithPinnedPage()
        let first = try #require(a.activeSpaceID)
        a.addSpace()
        let second = try #require(a.activeSpaceID)
        #expect(b.spaces.map(\.id) == [first, second])
        #expect(b.activeSpaceID == first)

        a.renameSpace(second, to: "Later")
        #expect(b.spaces.last?.name == "Later")

        await b.selectSpace(second)
        a.deleteSpace(second)
        #expect(b.spaces.map(\.id) == [first])
        // B was showing the deleted Space and falls back to one that exists.
        try await waitUntil { b.activeSpaceID == first }
        #expect(b.tabs.contains { $0.id == pinned })
    }

    @Test func noteDraftsAreSharedAndSurviveAnotherWindowLeaving() async throws {
        let library = makeLibrary()
        let a = AppModel(library: library)
        await a.loadIndex()
        let b = AppModel(library: library)
        await a.ensureInspectorNoteLoaded(Self.note)
        await b.ensureInspectorNoteLoaded(Self.note)
        #expect(b.inspectorNoteDraft(for: Self.note.path) == "disk body")

        a.setInspectorNoteDraft("edited in A", for: Self.note)
        #expect(b.inspectorNoteDraft(for: Self.note.path) == "edited in A")
        #expect(b.hasDirtyInspectorNotes)

        await a.open(Self.paths[1])              // A leaves: flushes and releases its notes
        #expect(b.inspectorNoteDraft(for: Self.note.path) == "edited in A")
        #expect(!library.notes.hasDirty)

        await b.open(Self.paths[2])              // last holder leaves: the clean entry goes
        #expect(library.notes.drafts[Self.note.path] == nil)
    }

    @Test func indexPublishRefreshesEveryWindowsList() async throws {
        let library = makeLibrary()
        let a = AppModel(library: library)
        let b = AppModel(library: library)
        await library.loadIndex()
        try await waitUntil { a.visibleEntries.count == 3 && b.visibleEntries.count == 3 }
        #expect(!a.isBootstrapping && !b.isBootstrapping)
    }

    @Test func everyOpenWindowIsSavedAndRestored() async throws {
        let suite = testDefaultsSuite("marple-multiwindow-")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)

        let library = makeLibrary(store: store)
        let a = AppModel(library: library)
        await a.loadIndex()
        await a.openInNewTab(Self.paths[0])
        let pinned = try #require(a.activeTabID)
        a.togglePin(pinned)
        let b = AppModel(library: library)
        await b.openInNewTab(Self.paths[2])
        b.windowFrame = "10 10 900 700 0 0 1440 900 "
        let bTemporary = try #require(b.activeTabID)

        let saved = try #require(store.load())
        #expect(saved.windows?.map(\.id) == [a.windowID, b.windowID])
        #expect(saved.spaces?.first?.tabs.map(\.id) == [pinned])

        let relaunched = makeLibrary(store: store)
        let ra = AppModel(library: relaunched, restoring: relaunched.takeRestoredWindow())
        let rb = AppModel(library: relaunched, restoring: relaunched.takeRestoredWindow())
        #expect(relaunched.takeRestoredWindow() == nil)
        #expect(ra.windowID == a.windowID)
        #expect(rb.windowID == b.windowID)
        #expect(rb.windowFrame == b.windowFrame)
        #expect(ra.tabs.map(\.id) == [pinned, bTemporary])
        #expect(rb.tabs.map(\.id) == [pinned, bTemporary])
        #expect(rb.activeTabID == bTemporary)
    }

    @Test func oldPerWindowTemporaryTabsAreMergedOnRestore() throws {
        let suite = testDefaultsSuite("marple-multiwindow-migration-")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        let space = SpaceDefinition(id: UUID(), name: "Work")
        let ids = [UUID(), UUID()]
        let windowIDs = [UUID(), UUID()]
        let windows = (0..<2).map { index in
            PersistedWindow(id: windowIDs[index], activeSpaceID: space.id, browsePane: .type(.paper),
                            sortClauses: [], filterClauses: [], filterMatch: .all, browseMode: "grid",
                            spaces: [PersistedSpaceSession(
                                spaceID: space.id, isBrowsing: false, activeTabID: ids[index],
                                temporaryTabs: [PersistedTab(id: ids[index],
                                    location: NavLocation(pane: .type(.paper), openPath: Self.paths[index]),
                                    pinned: false)], pinnedLocations: [], collapsedGroupIDs: [])])
        }
        store.save(PersistedState(definitions: [space], windows: windows, counts: nil,
                                  savedViews: nil, cache: { _ in (nil, nil) }))

        let library = makeLibrary(store: store)
        let a = AppModel(library: library, restoring: library.takeRestoredWindow())
        let b = AppModel(library: library, restoring: library.takeRestoredWindow())
        #expect(a.tabs.map(\.id) == ids)
        #expect(b.tabs.map(\.id) == ids)
        #expect(a.activeTabID == ids[0])
        #expect(b.activeTabID == ids[1])
        #expect(a.openPath == Self.paths[0])
        #expect(b.openPath == Self.paths[1])
    }

    @Test func closedWindowCanBeReopenedAndIsNotRestoredAsOpen() async throws {
        let suite = testDefaultsSuite("marple-multiwindow-")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        let library = makeLibrary(store: store)
        let a = AppModel(library: library)
        await a.loadIndex()
        var b: AppModel? = AppModel(library: library)
        await b?.openInNewTab(Self.paths[1])
        let closedID = try #require(b?.windowID)
        library.windowDidClose(try #require(b))
        b = nil

        #expect(store.load()?.windows?.map(\.id) == [a.windowID])
        #expect(store.load()?.recentlyClosedWindow?.id == closedID)
        let reopened = try #require(library.takeRecentlyClosedWindow())
        let window = AppModel(library: library, restoring: reopened)
        #expect(window.windowID == closedID)
        #expect(window.openPath == Self.paths[1])
        #expect(library.windows.count == 2)
    }

    @Test func newWindowStartsFromTheSourceSpaceWithItsTemporaryPages() async throws {
        let (library, a, _, pinned) = try await twoWindowsWithPinnedPage()
        await a.openInNewTab(Self.paths[2])
        a.addSpace()
        let space = try #require(a.activeSpaceID)
        let window = AppModel(library: library, restoring: a.newWindowState())
        #expect(window.windowID != a.windowID)
        #expect(window.activeSpaceID == space)
        let first = try #require(window.spaces.first?.workspace)
        #expect(first.tabs.map(\.id) == [pinned, try #require(a.spaces.first?.workspace?.tabs.last?.id)])
    }

    @Test func windowTitleNamesTheDocumentAndSpace() async throws {
        let library = makeLibrary()
        let a = AppModel(library: library)
        await a.loadIndex()
        let space = try #require(a.activeSpace?.name)
        #expect(a.windowTitle == space)
        await a.openInNewTab(Self.paths[0])
        #expect(a.windowTitle == "a.md — \(space)")
    }

    @Test func iPhoneMirrorFoldsWindowsTogether() throws {
        let item = SpaceDefinition.Item(id: UUID(), home: NavLocation(pane: .type(.paper), openPath: Self.paths[0]),
                                        customTitle: "Alias")
        let definition = SpaceDefinition(id: UUID(), name: "Work", roots: [
            .group(.init(id: UUID(), name: "F", children: [.item(item)])),
        ])
        func window(_ temporary: [String], active: String?) -> [WorkspaceSpace] {
            var space = WorkspaceSpace(definition: definition)
            for path in temporary {
                if space.workspace == nil { space.workspace = Workspace() }
                space.workspace?.newTab(NavLocation(pane: .type(.paper), openPath: path))
            }
            if let active, let id = space.workspace?.tabs.first(where: { $0.location.openPath == active })?.id {
                space.workspace?.select(id)
                space.isBrowsing = false
            }
            return [space]
        }
        let back = window([Self.paths[1], Self.paths[0]], active: nil)
        let front = window([Self.paths[2], Self.paths[1]], active: Self.paths[2])
        let mirror = SessionWriter.mirror(definitions: [definition], windows: [back, front], front: front,
                                          cache: { _ in (nil, nil) })
        let space = try #require(mirror.first)
        #expect(space.tabs.map(\.location.openPath) == [Self.paths[0], Self.paths[1], Self.paths[2]])
        #expect(space.tabs.map(\.pinned) == [true, false, false])
        #expect(space.tabs.first?.customTitle == "Alias")
        #expect(space.tabs[space.activeIndex].location.openPath == Self.paths[2])
        guard case .group(let folder) = space.tree?.roots.first else {
            Issue.record("expected the shared folder first"); return
        }
        #expect(!folder.isCollapsed)
        #expect(space.tree?.roots.count == 3)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }
}
