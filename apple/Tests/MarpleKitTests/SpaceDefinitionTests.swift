import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

extension PersistedState {
    /// The front window as the app restores it.
    var frontWindow: RestoredWindow? { restoredSession().windows.first }
    /// The front window's active Space's pages.
    var frontWorkspace: Workspace? {
        frontWindow.flatMap { window in window.spaces.first { $0.id == window.activeSpaceID }?.workspace }
    }
}

extension WorkspaceTreeSnapshot {
    /// Structure only — folder ids are generated when a tree without them is read.
    var withoutIDs: WorkspaceTreeSnapshot {
        func strip(_ nodes: [Node]) -> [Node] {
            nodes.map { node in
                guard case .group(var group) = node else { return node }
                group.id = nil
                group.children = strip(group.children)
                return .group(group)
            }
        }
        return WorkspaceTreeSnapshot(roots: strip(roots))
    }
}

@Suite struct SpaceDefinitionTests {
    let paper = NavLocation(pane: .type(.paper), openPath: "a.md")
    let book = NavLocation(pane: .type(.book), openPath: "b.md")
    let note = NavLocation(pane: .type(.note), openPath: "n.md")
    let other = NavLocation(pane: .type(.paper), openPath: "elsewhere.md")

    /// Folder "页面组 1" holding pinned A and B, then temporary T.
    func sample() throws -> (ws: Workspace, a: UUID, b: UUID, t: UUID, folder: UUID) {
        var ws = Workspace(initial: paper)
        let a = try #require(ws.activeID)
        let b = ws.newTab(book)
        ws.groupTabs([a, b])
        ws.togglePin(a)
        ws.togglePin(b)
        let t = ws.newTab(note)
        ws.flattenTemporaryTabs()
        let folder = try #require(ws.tabGroups.first?.id)
        return (ws, a, b, t, folder)
    }

    @Test func sharedRootsKeepPinnedPagesAndFoldersOnly() throws {
        let s = try sample()
        let roots = s.ws.sharedRoots
        guard case .group(let folder) = try #require(roots.first) else {
            Issue.record("expected a folder"); return
        }
        #expect(roots.count == 1)
        #expect(folder.id == s.folder)
        #expect(folder.children.map { node -> UUID? in
            if case .item(let item) = node { return item.id } else { return nil }
        } == [s.a, s.b])
        #expect(SpaceDefinition(id: UUID(), name: "x", roots: roots).items.map(\.home) == [paper, book])
    }

    @Test func rebaseKeepsThisWindowsReadingStateByID() throws {
        var source = try sample()
        var window = source.ws
        // This window reads elsewhere from A, collapses the folder, keeps its temp page.
        window.select(source.a)
        window.navigateActive(to: other)
        window.setGroupCollapsed(source.folder, collapsed: true)

        // Another window renames A and pins a new page C at the root.
        source.ws.renameTab(source.a, to: "Alias")
        let c = source.ws.newTab(NavLocation(pane: .type(.paper), openPath: "c.md"))
        source.ws.togglePin(c)
        source.ws.flattenTemporaryTabs()

        window.rebase(onto: source.ws.sharedRoots)
        let a = try #require(window.tabs.first { $0.id == source.a })
        #expect(a.customTitle == "Alias")
        #expect(a.location == other)
        #expect(a.history.canGoBack)
        #expect(a.pinnedLocation == paper)
        #expect(window.activeID == source.a)
        #expect(window.tabs.first { $0.id == c }?.location == NavLocation(pane: .type(.paper), openPath: "c.md"))
        #expect(window.tabs.first { $0.id == source.t }?.pinned == false)
        #expect(window.collapsedGroupIDs == [source.folder])
        #expect(window.tabs.last?.id == source.t)
    }

    @Test func droppedPinnedPageSurvivesOnlyWhereItIsBeingRead() throws {
        var source = try sample()
        var reading = source.ws
        reading.select(source.a)
        reading.navigateActive(to: other)
        let idle = source.ws

        // Another window unpins A (it moves to its temporary run there).
        source.ws.togglePin(source.a)
        source.ws.flattenTemporaryTabs()

        var rebasedIdle = idle
        rebasedIdle.rebase(onto: source.ws.sharedRoots)
        #expect(!rebasedIdle.tabs.contains { $0.id == source.a })
        #expect(!rebasedIdle.tabs.contains { $0.location == paper })

        reading.rebase(onto: source.ws.sharedRoots)
        let survivor = try #require(reading.activeTab)
        #expect(survivor.id != source.a)
        #expect(!survivor.pinned)
        #expect(survivor.location == other)
        #expect(survivor.history.canGoBack)
    }

    @Test func newFormatRoundTripsWindowsOverSharedDefinitions() throws {
        var s = try sample()
        s.ws.select(s.b)
        s.ws.navigateActive(to: other)
        s.ws.setGroupCollapsed(s.folder, collapsed: true)
        let space = WorkspaceSpace(name: "Work", workspace: s.ws, isBrowsing: false)
        let empty = WorkspaceSpace(name: "Empty", workspace: nil, isBrowsing: true)
        let window = PersistedWindow(
            id: UUID(), frame: "0 0 800 600 0 0 1440 900 ", activeSpaceID: space.id,
            browsePane: .type(.book), sortClauses: [], filterClauses: [], filterMatch: .any,
            browseMode: "list",
            spaces: [space, empty].map { PersistedSpaceSession(space: $0, cache: { _ in (nil, nil) }) })
        let state = PersistedState(definitions: [space.definition, empty.definition], windows: [window],
                                   counts: nil, savedViews: nil, cache: { _ in ("Live", .paper) })

        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        let restored = try #require(decoded.restoredSession().windows.first)
        #expect(restored.id == window.id)
        #expect(restored.frame == window.frame)
        #expect(restored.activeSpaceID == space.id)
        #expect(restored.browsePane == .type(.book))
        #expect(restored.filterMatch == .any)
        let ws = try #require(restored.spaces.first?.workspace)
        #expect(ws.tabs.map(\.id) == [s.a, s.b, s.t])
        #expect(ws.tabs.map(\.pinned) == [true, true, false])
        #expect(ws.activeID == s.b)
        #expect(ws.activeTab?.location == other)
        #expect(ws.activeTab?.pinnedLocation == book)
        #expect(ws.collapsedGroupIDs == [s.folder])
        #expect(ws.tabs.first?.cachedTitle == "Live")
        #expect(restored.spaces.first?.isBrowsing == false)
        #expect(restored.spaces.map(\.name) == ["Work", "Empty"])

        // An older build reads the shared part: pinned pages and folders, no temp page.
        let legacy = try #require(decoded.makeSpaces().spaces.first?.workspace)
        #expect(legacy.tabs.map(\.location) == [paper, book])
        #expect(legacy.tabGroups.count == 1)
    }

    @Test func legacyStateMigratesIntoOneWindowWithStableIDs() throws {
        let tabs = [
            PersistedTab(location: paper, pinned: true),
            PersistedTab(location: book, pinned: true),
            PersistedTab(location: note, pinned: false),
        ]
        let tree = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "Folder", isCollapsed: true, children: [.tab(0), .tab(1)])),
            .tab(2),
        ])
        let space = PersistedWorkspaceSpace(name: "Work", isBrowsing: false, tabs: tabs,
                                            activeIndex: 2, tree: tree)
        let legacy = PersistedState(browsePane: .type(.note), isBrowsing: false, tabs: tabs,
                                    activeIndex: 2, sortClauses: [], filterClauses: [],
                                    filterMatch: .all, browseMode: "grid",
                                    currentSpace: space, spaces: [space], activeSpaceID: space.id)

        let first = legacy.restoredSession()
        #expect(first.windows.count == 1)
        let window = try #require(first.windows.first)
        #expect(window.browsePane == .type(.note))
        let ws = try #require(window.spaces.first?.workspace)
        #expect(ws.tabs.map(\.location) == [paper, book, note])
        #expect(ws.activeTab?.location == note)
        #expect(ws.collapsedGroupIDs.count == 1)
        #expect(first.definitions.first?.items.map(\.home) == [paper, book])

        // Saving the migrated window and reading it back keeps every id.
        let saved = PersistedState(
            definitions: first.definitions,
            windows: [PersistedWindow(id: window.id, activeSpaceID: window.activeSpaceID,
                                      browsePane: window.browsePane, sortClauses: [],
                                      filterClauses: [], filterMatch: .all, browseMode: "grid",
                                      spaces: window.spaces.map {
                                          PersistedSpaceSession(space: $0, cache: { _ in (nil, nil) })
                                      })],
            counts: nil, savedViews: nil, cache: { _ in (nil, nil) })
        let again = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(saved))
            .restoredSession()
        let ws2 = try #require(again.windows.first?.spaces.first?.workspace)
        #expect(ws2.tabs.map(\.id) == ws.tabs.map(\.id))
        #expect(ws2.tabGroups.map(\.id) == ws.tabGroups.map(\.id))
        #expect(ws2.collapsedGroupIDs == ws.collapsedGroupIDs)
        #expect(ws2.activeID == ws.activeID)
    }

    @Test func duplicateSavedPageIDsAreReassigned() throws {
        let id = UUID()
        let one = PersistedWorkspaceSpace(name: "One", tabs: [PersistedTab(id: id, location: paper, pinned: true)])
        let two = PersistedWorkspaceSpace(name: "Two", tabs: [PersistedTab(id: id, location: book, pinned: true)])
        let state = PersistedState(browsePane: .type(.paper), isBrowsing: true, tabs: [], activeIndex: 0,
                                   sortClauses: [], filterClauses: [], filterMatch: .all,
                                   browseMode: "", spaces: [one, two])
        let items = state.restoredSession().definitions.flatMap(\.items)
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        #expect(items.first?.id == id)
    }

    @MainActor
    @Test func relaunchRestoresPagesWhereTheyWere() async throws {
        let suite = testDefaultsSuite("marple-multiwindow-")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        let entries = ["a", "b", "c"].map { name in
            Entry(path: "vault/papers/\(name).md", type: .paper, title: name, author: [], year: nil,
                  ratingScore: 0, themes: [], preview: "", hasPDF: false)
        }
        let client = StubVaultClient(entries: entries,
                                     texts: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, "# x") }))
        let model = AppModel(client: client, stateStore: store)
        await model.loadIndex()
        await model.openInNewTab(entries[0].path)
        let pinned = try #require(model.activeTabID)
        model.togglePin(pinned)
        await model.open(entries[1].path)          // pinned page reads off its anchor
        await model.openInNewTab(entries[2].path)  // temporary page
        let temporary = try #require(model.activeTabID)

        let relaunched = AppModel(client: client, stateStore: store)
        #expect(relaunched.windowID == model.windowID)
        #expect(relaunched.tabs.map(\.id) == [pinned, temporary])
        #expect(relaunched.tabs.first?.location.openPath == entries[1].path)
        #expect(relaunched.tabs.first?.pinnedLocation?.openPath == entries[0].path)
        #expect(relaunched.activeTabID == temporary)
    }
}
