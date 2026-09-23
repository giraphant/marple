import Foundation
import Synchronization
import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct NavigationPersistenceTests {
    @MainActor
    @Test func navigationSavesCompleteListContextOnceBeforeReading() async throws {
        let suite = "marple-navigation-context-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CountingStateStore(backing: UserDefaultsStateStore(defaults: defaults))
        let contexts = [
            ListContext(searchText: "", filters: [.init(field: .year, op: .gte, value: "2000")],
                        filterMatch: .any, sorts: [.init(field: .title, dir: .asc)]),
            ListContext(searchText: "", filters: [], filterMatch: .all, sorts: [])
        ]
        let types: [EntryType] = [.book, .paper]
        let entries = types.enumerated().map { index, type in
            Entry(path: "vault/\(type.rawValue)/\(index).md", type: type, title: "\(index)",
                  author: [], year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        }
        let tabs = entries.enumerated().map { index, entry in
            PersistedTab(location: NavLocation(pane: .type(entry.type), openPath: entry.path,
                                              listContext: contexts[index]), pinned: false)
        }
        let first = PersistedWorkspaceSpace(name: "First", tabs: tabs, activeIndex: 1)
        let second = PersistedWorkspaceSpace(name: "Second", tabs: [tabs[0]])
        store.save(PersistedState(browsePane: .type(.paper), isBrowsing: false, tabs: tabs,
            activeIndex: 1, sortClauses: [], filterClauses: [], filterMatch: .all, browseMode: "grid",
            currentSpace: first, spaces: [first, second], activeSpaceID: first.id))
        let gate = DocLoadGate()
        let client = GatedVaultClient(base: StubVaultClient(entries: entries,
            texts: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, "# Document") })),
            blockedPath: entries[0].path, gate: gate)
        let model = AppModel(client: client, stateStore: store)
        await model.loadIndex()
        let bookTab = try #require(model.tabs.first?.id)
        for action in 0..<6 {
            let before = store.saveCount
            let selection = Task { @MainActor in
                switch action {
                case 0: await model.selectTab(bookTab)
                case 1: await model.selectTab(index: 1)
                case 2: await model.selectNextTab()
                case 3: await model.selectPrevTab()
                case 4: await model.selectSpace(second.id)
                default: await model.selectSpace(first.id)
                }
            }
            let target = action % 2
            if target == 0 { await gate.waitUntilBlocked() }
            else { await selection.value }
            // Check while entryText is suspended: persistence must already be complete.
            #expect(store.saveCount - before == 1, Comment(rawValue: "action \(action)"))
            let saved = store.load()
            #expect(saved?.browsePane == .type(types[target]))
            #expect(saved?.filterClauses == contexts[target].filters)
            #expect(saved?.filterMatch == contexts[target].filterMatch)
            #expect(saved?.sortClauses == contexts[target].sorts)
            #expect(saved?.makeWorkspace()?.activeTab?.location.openPath == entries[target].path)
            #expect(saved?.activeSpaceID == (action == 4 ? second.id : first.id))
            if target == 0 { await gate.release() }
            await selection.value
        }
    }

    @MainActor
    @Test func switchingTabsAndSpacesSavesOnlyChangedState() async throws {
        let suite = "marple-navigation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CountingStateStore(backing: UserDefaultsStateStore(defaults: defaults))
        let entries = ["a", "b"].map { (name: String) in
            Entry(path: "vault/papers/\(name).md", type: .paper, title: name,
                  author: [], year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        }
        let model = AppModel(client: StubVaultClient(
            entries: entries, texts: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, "# \($0.title!)") })),
            stateStore: store)
        await model.loadIndex()
        await model.openInNewTab(entries[0].path)
        await model.openInNewTab(entries[1].path)
        let firstTab = try #require(model.tabs.first?.id)
        let firstSpace = try #require(model.activeSpaceID)

        var before = store.saveCount
        await model.selectTab(firstTab)
        #expect(store.saveCount - before == 1)
        #expect(store.load()?.activeIndex == 0)
        #expect(store.load()?.tabs.map(\.cachedTitle) == ["a", "b"])

        model.addSpace()
        await model.openInNewTab(entries[1].path)
        before = store.saveCount
        await model.selectSpace(firstSpace)
        #expect(store.saveCount - before == 1)
        #expect(store.load()?.activeSpaceID == firstSpace)
        #expect(store.load()?.makeWorkspace()?.activeTab?.location.openPath == entries[0].path)
    }
}

private final class CountingStateStore: StateStore, Sendable {
    let backing: UserDefaultsStateStore
    private let count = Mutex(0)
    var saveCount: Int { count.withLock { $0 } }

    init(backing: UserDefaultsStateStore) { self.backing = backing }
    func load() -> PersistedState? { backing.load() }
    func save(_ state: PersistedState) {
        count.withLock { $0 += 1 }
        backing.save(state)
    }
}
