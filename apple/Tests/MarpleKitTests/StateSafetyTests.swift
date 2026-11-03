import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

/// Saved Spaces must survive a build that cannot read part (or all) of them: the
/// 2026-11-03 data loss was one unknown sort field failing the whole blob, which
/// the app then overwrote with a fresh "空间 1".
@Suite struct StateSafetyTests {
    private let fm = FileManager.default

    private func makeStore(_ data: Data) throws -> (UserDefaultsStateStore, UserDefaults, URL, () -> Void) {
        let suite = testDefaultsSuite("marple-state-safety-")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(data, forKey: UserDefaultsStateStore.defaultKey)
        let backups = fm.temporaryDirectory.appendingPathComponent("marple-state-backups-\(UUID().uuidString)")
        let store = UserDefaultsStateStore(defaults: defaults, backupDirectory: backups)
        return (store, defaults, backups, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: backups)
        })
    }

    private func tab(_ path: String, context: ListContext? = nil) -> PersistedTab {
        PersistedTab(location: NavLocation(pane: .type(.paper), openPath: path, listContext: context),
                     pinned: true)
    }

    /// One Space: folder "A" holding tabs 0 and 2, tab 1 at the root; plus an archived Space.
    private func sampleJSON() throws -> [String: Any] {
        let tree = WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "A", isCollapsed: false, children: [.tab(0), .tab(2)])),
            .tab(1)
        ])
        let space = PersistedWorkspaceSpace(name: "Work", tabs: [tab("a.md"), tab("b.md"), tab("c.md")],
                                            activeIndex: 2, tree: tree)
        let archived = PersistedWorkspaceSpace(name: "Old", tabs: [tab("z.md")], isArchived: true)
        let state = PersistedState(browsePane: .type(.paper), isBrowsing: false, tabs: [], activeIndex: 0,
                                   sortClauses: [SortClause(field: .title, dir: .asc)], filterClauses: [],
                                   filterMatch: .all, browseMode: "grid",
                                   spaces: [space, archived], activeSpaceID: space.id)
        let data = try JSONEncoder().encode(state)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encode(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json)
    }

    @Test func readableStateWritesNoBackup() throws {
        let (store, _, backups, cleanup) = try makeStore(try encode(try sampleJSON()))
        defer { cleanup() }
        let result = store.loadResult()
        #expect(result.state?.spaces?.count == 2)
        #expect(!result.hadErrors)
        #expect(result.allowsSaving)
        #expect(!fm.fileExists(atPath: backups.path))
    }

    @Test func unreadableTabIsSkippedAndFoldersKeepTheirTabs() throws {
        var json = try sampleJSON()
        var spaces = try #require(json["spaces"] as? [[String: Any]])
        var tabs = try #require(spaces[0]["tabs"] as? [[String: Any]])
        var location = try #require(tabs[0]["location"] as? [String: Any])
        location["pane"] = ["paneFromAnotherBuild": ["_0": "x"]]
        tabs[0]["location"] = location
        spaces[0]["tabs"] = tabs
        json["spaces"] = spaces
        let original = try encode(json)
        let (store, _, _, cleanup) = try makeStore(original)
        defer { cleanup() }

        let result = store.loadResult()
        let restored = try #require(result.state?.spaces)
        #expect(result.hadErrors)
        #expect(result.allowsSaving)
        #expect(try Data(contentsOf: try #require(result.backupURL)) == original)
        #expect(restored.count == 2)
        #expect(restored[1].isArchived)
        let work = restored[0]
        #expect(work.tabs.map(\.location.openPath) == ["b.md", "c.md"])
        #expect(work.activeIndex == 1)
        // c.md stays in folder A, b.md stays at the root.
        #expect(work.tree == WorkspaceTreeSnapshot(roots: [
            .group(.init(name: "A", isCollapsed: false, children: [.tab(1)])),
            .tab(0)
        ]))
    }

    @Test func unknownSortFieldDropsOnlyThatClause() throws {
        var json = try sampleJSON()
        let unknownSort: [String: Any] = ["field": "fieldFromAnotherBuild", "dir": "asc"]
        json["sortClauses"] = (json["sortClauses"] as? [Any] ?? []) + [unknownSort]
        var spaces = try #require(json["spaces"] as? [[String: Any]])
        var tabs = try #require(spaces[0]["tabs"] as? [[String: Any]])
        var location = try #require(tabs[1]["location"] as? [String: Any])
        location["listContext"] = ["searchText": "q", "filters": [], "filterMatch": "all",
                                   "sorts": [unknownSort]]
        tabs[1]["location"] = location
        spaces[0]["tabs"] = tabs
        json["spaces"] = spaces
        let (store, _, _, cleanup) = try makeStore(try encode(json))
        defer { cleanup() }

        let result = store.loadResult()
        let state = try #require(result.state)
        #expect(result.hadErrors)
        #expect(state.sortClauses == [SortClause(field: .title, dir: .asc)])
        let work = try #require(state.spaces?.first)
        #expect(work.tabs.count == 3)
        #expect(work.tabs[1].location.listContext?.searchText == "q")
        #expect(work.tabs[1].location.listContext?.sorts == [])
    }

    @MainActor
    @Test func unreadableStateIsBackedUpAndNeverOverwritten() throws {
        let original = Data("{\"spaces\": not json".utf8)
        let (store, defaults, _, cleanup) = try makeStore(original)
        defer { cleanup() }

        let result = store.loadResult()
        #expect(result.state == nil)
        #expect(!result.allowsSaving)
        #expect(try Data(contentsOf: try #require(result.backupURL)) == original)

        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]), stateStore: store)
        model.select(pane: .type(.book))
        #expect(model.spaces.count == 1)
        #expect(defaults.data(forKey: UserDefaultsStateStore.defaultKey) == original)
    }

    @Test func snapshotCarriesPersistedState() throws {
        let vault = fm.temporaryDirectory.appendingPathComponent("marple-state-vault-\(UUID().uuidString)")
        let base = fm.temporaryDirectory.appendingPathComponent("marple-state-snapshots-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: base) }
        try fm.createDirectory(at: vault.appendingPathComponent("vault"), withIntermediateDirectories: true)
        let state = Data("{\"spaces\":[]}".utf8)

        let snapshot = try SnapshotStore(workspaceRoot: vault, backupsBase: base).snapshot(persistedState: state)

        let copy = snapshot.url.appendingPathComponent(SnapshotStore.persistedStateFilename)
        #expect(try Data(contentsOf: copy) == state)
    }
}
