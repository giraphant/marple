import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

/// `AppModel.loadIndex()` is called from three concurrent paths in production:
/// the fast-path deferred reconcile (MarpleApp.swift), the FSEvents watcher, and
/// (post-QUA-105) the background full-hydration task. Without a generation
/// guard, an older call resuming after a newer one's snapshot was published
/// would overwrite `entries` / `trashItems` with stale data. These tests pin
/// that invariant.
@Suite struct AppModelLoadIndexTests {
    @MainActor
    @Test func staleLoadIndexDoesNotOverwriteFresherEntries() async throws {
        let older = Self.entry("vault/notes/older.md")
        let newer1 = Self.entry("vault/notes/newer1.md")
        let newer2 = Self.entry("vault/notes/newer2.md")

        let client = ScriptedDelayedClient()
        // Two scripted index() responses; ordering controlled by per-call delays.
        client.queueIndex(entries: [older],          delayMs: 250)   // call #0 (older)
        client.queueIndex(entries: [newer1, newer2], delayMs: 20)    // call #1 (newer)

        let model = AppModel(client: client)

        async let first: Void = model.loadIndex()
        // Yield to give the first call a chance to enter loadIndex and bump
        // generation before the second call captures its own snapshot. Without
        // this nudge, both calls would race for `loadIndexGeneration` and the
        // outcome would be schedule-dependent rather than the deterministic
        // "older suspends, newer overtakes" we want to exercise.
        try await Task.sleep(nanoseconds: 5_000_000)
        async let second: Void = model.loadIndex()

        _ = await (first, second)

        // Newer call published; older's late return was dropped by the gen guard.
        #expect(model.entries.map(\.path) == [newer1.path, newer2.path])
    }

    @MainActor
    @Test func staleLoadIndexFailureDoesNotOverwriteFresherStatus() async throws {
        let newer = Self.entry("vault/notes/newer.md")

        let client = ScriptedDelayedClient()
        client.queueIndexFailure(delayMs: 200)                  // call #0 (older, fails late)
        client.queueIndex(entries: [newer], delayMs: 20)         // call #1 (newer, succeeds first)

        let model = AppModel(client: client)

        async let first: Void = model.loadIndex()
        try await Task.sleep(nanoseconds: 5_000_000)
        async let second: Void = model.loadIndex()

        _ = await (first, second)

        // Older failure resumed last but was dropped — the newer success's status stays.
        #expect(model.status == "1 entries")
        #expect(model.entries.map(\.path) == [newer.path])
    }

    // MARK: - isBootstrapping (QUA-105)

    @MainActor
    @Test func appModelStartsInBootstrappingState() {
        let client = ScriptedDelayedClient()
        let model = AppModel(client: client)
        #expect(model.isBootstrapping == true)
    }

    @MainActor
    @Test func successfulLoadIndexClearsBootstrapping() async {
        let client = ScriptedDelayedClient()
        client.queueIndex(entries: [Self.entry("vault/notes/a.md")], delayMs: 0)
        let model = AppModel(client: client)
        await model.loadIndex()
        #expect(model.isBootstrapping == false)
    }

    @MainActor
    @Test func failedLoadIndexAlsoClearsBootstrapping() async {
        // First load fails — views should still escape skeleton state (status
        // string carries the error message; the alternative would be a forever-
        // skeleton UI on a corrupt index).
        let client = ScriptedDelayedClient()
        client.queueIndexFailure(delayMs: 0)
        let model = AppModel(client: client)
        await model.loadIndex()
        #expect(model.isBootstrapping == false)
        #expect(model.status.starts(with: "index failed"))
    }

    @MainActor
    @Test func emptyVaultStillClearsBootstrapping() async {
        // Real empty vault — entries.isEmpty after load is NOT the same as
        // "still bootstrapping". This is the case Codex flagged about empty-
        // state views (EntryGridView drop-zone, ThemesView) — they need to
        // distinguish skeleton-while-loading from genuine-empty.
        let client = ScriptedDelayedClient()
        client.queueIndex(entries: [], delayMs: 0)
        let model = AppModel(client: client)
        await model.loadIndex()
        #expect(model.isBootstrapping == false)
        #expect(model.entries.isEmpty)
    }

    @MainActor
    @Test func staleLoadIndexDoesNotResetBootstrapping() async throws {
        // Same race as `staleLoadIndexDoesNotOverwriteFresherEntries`, but the
        // invariant we're pinning is the bootstrap flag — once a newer call
        // has flipped it false, a stale older call must not flip it back true
        // (or otherwise touch it).
        let client = ScriptedDelayedClient()
        client.queueIndex(entries: [Self.entry("vault/notes/older.md")], delayMs: 250)
        client.queueIndex(entries: [Self.entry("vault/notes/newer.md")], delayMs: 20)

        let model = AppModel(client: client)
        async let first: Void = model.loadIndex()
        try await Task.sleep(nanoseconds: 5_000_000)
        async let second: Void = model.loadIndex()
        _ = await (first, second)

        #expect(model.isBootstrapping == false)
    }

    // MARK: - isRefreshing counter (QUA-105)

    @MainActor
    @Test func refreshingDefaultsToFalse() {
        let model = AppModel(client: ScriptedDelayedClient())
        #expect(model.isRefreshing == false)
    }

    @MainActor
    @Test func refreshingCounterIsReentrantSafe() {
        // Two overlapping background refreshes (deferred reconcile + watcher,
        // or two FSEvents bursts firing close together) must not race the
        // indicator off while the second is still running. Counter-based.
        let model = AppModel(client: ScriptedDelayedClient())
        model.beginRefreshing()
        #expect(model.isRefreshing == true)
        model.beginRefreshing()
        #expect(model.isRefreshing == true)
        model.endRefreshing()
        #expect(model.isRefreshing == true)   // still one outstanding
        model.endRefreshing()
        #expect(model.isRefreshing == false)
    }

    @MainActor
    @Test func endRefreshingClampsAtZero() {
        // Defensive: stray endRefreshing without a matching begin must not
        // make the counter go negative (it would then take an extra begin to
        // recover, and the indicator would be permanently desynced).
        let model = AppModel(client: ScriptedDelayedClient())
        model.endRefreshing()
        model.endRefreshing()
        #expect(model.isRefreshing == false)
        model.beginRefreshing()
        #expect(model.isRefreshing == true)
    }

    @MainActor
    @Test func sequentialLoadIndexCallsStillPublish() async throws {
        // Sanity: the gen guard must not break the common case of back-to-back
        // sequential calls (each one publishes its own result).
        let first = Self.entry("vault/notes/first.md")
        let second = Self.entry("vault/notes/second.md")

        let client = ScriptedDelayedClient()
        client.queueIndex(entries: [first],  delayMs: 0)
        client.queueIndex(entries: [second], delayMs: 0)

        let model = AppModel(client: client)
        await model.loadIndex()
        #expect(model.entries.map(\.path) == [first.path])

        await model.loadIndex()
        #expect(model.entries.map(\.path) == [second.path])
    }

    // MARK: - cachedTitle / counts bootstrap fallback (QUA-105 follow-up)

    @MainActor
    @Test func tabTitleFallsThroughCachedTitleDuringBootstrap() async throws {
        // Construct an AppModel restored from persisted state with a tab whose
        // cachedTitle is set — entries is empty (bootstrap), so the live title
        // lookup fails. tabTitle() must return the cached title rather than
        // the filename basename.
        let path = "vault/notes/long-filename.md"
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        store.save(PersistedState(
            browsePane: .type(.note),
            isBrowsing: false,
            tabs: [PersistedTab(
                location: NavLocation(pane: .type(.note), openPath: path),
                pinned: false,
                customTitle: nil,
                cachedTitle: "Real Document Title")],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "list"))

        let model = AppModel(client: ScriptedDelayedClient(), stateStore: store)
        let tab = try #require(model.tabs.first)
        #expect(model.entries.isEmpty)                          // bootstrap
        #expect(model.tabTitle(tab) == "Real Document Title")   // not "long-filename.md"
    }

    @MainActor
    @Test func tabTitleUsesLiveEntryOnceLoaded() async throws {
        // Once loadIndex publishes, the live entry's title should win over
        // the cached one — cachedTitle is fallback only.
        let path = "vault/notes/n.md"
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        store.save(PersistedState(
            browsePane: .type(.note),
            isBrowsing: false,
            tabs: [PersistedTab(
                location: NavLocation(pane: .type(.note), openPath: path),
                pinned: false,
                customTitle: nil,
                cachedTitle: "Stale Title")],
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "list"))

        let live = Entry(path: path, type: .note, title: "Live Title", author: [],
                         year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let client = ScriptedDelayedClient()
        client.queueIndex(entries: [live], delayMs: 0)
        let model = AppModel(client: client, stateStore: store)
        await model.loadIndex()
        let tab = try #require(model.tabs.first)
        #expect(model.tabTitle(tab) == "Live Title")
    }

    @MainActor
    @Test func loadIndexPersistsLiveTitlesAndCountsAfterFirstPublish() async throws {
        // Without an explicit persist() call inside loadIndex, a "boot and
        // quit without interaction" session would never round-trip live
        // titles/counts into PersistedState — because the only persist()
        // triggers are didSet on browsePane/workspace/etc., none of which
        // fires while the app simply finishes loading. This regression test
        // pins the post-publish persist.
        let path = "vault/notes/n.md"
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        // Pre-seed a tab pointing at the path so loadIndex's title snapshot
        // has something to attach to.
        store.save(PersistedState(
            browsePane: .type(.note),
            isBrowsing: false,
            tabs: [PersistedTab(
                location: NavLocation(pane: .type(.note), openPath: path),
                pinned: false)],     // cachedTitle deliberately nil — stale legacy
            activeIndex: 0,
            sortClauses: [],
            filterClauses: [],
            filterMatch: .all,
            browseMode: "list"))

        let live = Entry(path: path, type: .note, title: "Real Title", author: [],
                         year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let client = ScriptedDelayedClient()
        client.queueIndex(entries: [live], delayMs: 0)
        let model = AppModel(client: client, stateStore: store)
        await model.loadIndex()

        let onDisk = try #require(store.load())
        // Tab cachedTitle should now carry the live entry title.
        #expect(onDisk.tabs.first?.cachedTitle == "Real Title")
        // counts should reflect the live distribution (one note).
        #expect(onDisk.counts == [.note: 1])
        _ = model
    }

    @MainActor
    @Test func appModelInitDoesNotWipeStoredCountsBeforeLoadIndex() throws {
        // Regression: persist() fires via didSet on browsePane/workspace/etc.
        // during AppModel.init, BEFORE loadIndex runs. Without loadedCountsSnapshot
        // being seeded first, those persist() calls would round-trip an empty
        // counts dict over the user's previously-saved type counts — and the
        // *next* launch (no entries published yet) would then show all zeros
        // permanently, defeating the whole point of persisting counts.
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        let seeded: [EntryType: Int] = [.note: 7, .paperAnalysis: 23]
        var state = PersistedState(
            browsePane: .type(.note),
            isBrowsing: true,
            tabs: [],
            activeIndex: 0,
            sortClauses: [], filterClauses: [], filterMatch: .all, browseMode: "list")
        state.counts = seeded
        store.save(state)

        // Construct AppModel — its init triggers multiple persist() calls.
        _ = AppModel(client: ScriptedDelayedClient(), stateStore: store)

        // Disk state must still carry the user's counts, not an empty dict.
        let onDisk = try #require(store.load())
        #expect(onDisk.counts == seeded)
    }

    @MainActor
    @Test func countsSeedFromPersistedStateOnInit() throws {
        let suite = "marple.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStateStore(defaults: defaults)
        let seeded: [EntryType: Int] = [.note: 7, .paperAnalysis: 23]
        var state = PersistedState(
            browsePane: .type(.note),
            isBrowsing: true,
            tabs: [],
            activeIndex: 0,
            sortClauses: [], filterClauses: [], filterMatch: .all, browseMode: "list")
        state.counts = seeded
        store.save(state)

        let model = AppModel(client: ScriptedDelayedClient(), stateStore: store)
        #expect(model.counts == seeded)              // stale-but-plausible from t=0
        #expect(model.isBootstrapping == true)        // entries haven't loaded
    }

    // MARK: helpers

    private static func entry(_ path: String) -> Entry {
        Entry(path: path, type: .note, title: path, author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }

    /// VaultClient stub whose `index()` answers a queued script in order, each
    /// entry with an artificial delay. Lets tests stage call N to finish AFTER
    /// call N+1 deterministically, exercising the generation guard.
    private final class ScriptedDelayedClient: VaultClient, @unchecked Sendable {
        private enum Step {
            case ok([Entry], delayMs: Int)
            case fail(delayMs: Int)
        }
        private let queue = DispatchQueue(label: "MarpleKitTests.ScriptedDelayedClient")
        private var script: [Step] = []
        private var next = 0

        func queueIndex(entries: [Entry], delayMs: Int) {
            queue.sync { script.append(.ok(entries, delayMs: delayMs)) }
        }

        func queueIndexFailure(delayMs: Int) {
            queue.sync { script.append(.fail(delayMs: delayMs)) }
        }

        func index() async throws -> [Entry] {
            let step: Step = queue.sync {
                let s = script[next]
                next += 1
                return s
            }
            switch step {
            case .ok(let entries, let delayMs):
                if delayMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
                return entries
            case .fail(let delayMs):
                if delayMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
                throw VaultError.notFound("scripted failure")
            }
        }

        func search(_ query: SearchQuery) async throws -> [SearchHit] { [] }
        func entryText(path: String) async throws -> String { "" }
        func openInEditor(path: String, app: String) async throws {}
        func openPDF(slug: String) async throws {}
        func openTranslation(slug: String) async throws {}
        func hasTranslation(slug: String) -> Bool { false }
        func imageOriginalURL(forImageEntryPath path: String) async throws -> URL? { nil }
        func createImageObject(from sourceURL: URL, title: String?) async throws -> Entry {
            throw VaultError.notFound(sourceURL.path)
        }
        func writeFile(path: String, text: String) async throws {}
        func createNote(path: String, text: String) async throws {}
        func moveToTrash(path: String) async throws -> String { "" }
        func listTrash() async throws -> [TrashItem] { [] }
        func restoreTrash(name: String) async throws -> String { "" }
        func purgeTrash(name: String) async throws {}
    }
}
