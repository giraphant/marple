import Foundation
import MarpleKit
import Observation

/// Everything one vault shares across windows: the vault client and index, the
/// single Catalog and its refresh authority, the shared Space definitions, saved
/// views and type preferences, trash and archive collections, right-rail note
/// drafts, and the one writer of saved state. Each window is an `AppModel` that
/// reads and writes this through forwarding properties and keeps its own reading
/// state. See docs/multi-window-design.md.
@Observable @MainActor
final class Library {
    let client: VaultClient
    let workspaceRoot: String
    /// True when this session has no reusable index sidecar.
    let isFirstRun: Bool
    let catalog = Catalog()
    let notes: NoteDraftStore
    /// Organization edits (sidebar structure, type order, views) from every window
    /// land on this one stack, so undo replays them in the order they happened.
    @ObservationIgnored let undoManager = UndoManager()

    @ObservationIgnored let searchDefaults: UserDefaults
    @ObservationIgnored let stateStore: StateStore?
    @ObservationIgnored let readerAIRunner: ReaderAIRunner
    @ObservationIgnored let metadataWriter: MetadataWriter
    /// Publishes open pages to the synced folder for the iOS companion. nil without
    /// a workspace root (e.g. tests).
    @ObservationIgnored let sessionWriter: SessionWriter?
    var semantic: (any SemanticBackend)?

    /// The vault indexer, injected at boot (see `AppModel.cliIndexer`). nil in stub tests.
    var cliIndexer: VaultIndexer?
    var termIndexController: TermIndexController?

    var status = ""
    var lastIndexFailure: String?
    var isRebuildingGeneralIndex = false
    /// True until the first `loadIndex()` publishes a snapshot or reports an error.
    var isBootstrapping = true
    private var refreshingCount = 0
    var isRefreshing: Bool { refreshingCount > 0 }

    var schemaSnapshot: SchemaSnapshot?
    var localisation: CnDoubanIndex?
    var trashItems: [TrashItem] = []

    var archiveCollections: [ArchiveCollection] = []
    var archiveCollectionNeedsIndexReload = false
    var archiveCollectionBusy = false
    var archiveCollectionError: String?

    var savedViews: [SavedView] = [] {
        didSet {
            persist()
            catalog.recomputeSavedViewCounts(savedViews: savedViews)
        }
    }

    /// User-customised sidebar type order, persisted separately via UserDefaults.
    var typeOrder: [EntryType] = EntryType.modeled {
        didSet { persistTypeOrder() }
    }

    /// Sidebar-hidden type buckets (QUA-127), persisted like `typeOrder`.
    var hiddenTypes: Set<EntryType> = [] {
        didSet { persistHiddenTypes() }
    }

    /// The shared part of every Space, in switcher order.
    private(set) var spaceDefinitions: [SpaceDefinition] = []

    // MARK: windows

    @ObservationIgnored private var windowRefs: [WeakModel] = []
    /// Front-to-back order of windows, supplied by the app (AppKit window order).
    /// Without it, registration order.
    @ObservationIgnored var frontToBack: (([AppModel]) -> [AppModel])?

    /// Open windows, registration (creation) order.
    var windows: [AppModel] {
        windowRefs.removeAll { $0.value == nil }
        return windowRefs.compactMap(\.value)
    }

    /// Open windows, front first.
    var orderedWindows: [AppModel] {
        let all = windows
        return frontToBack?(all) ?? all
    }

    // MARK: restore + save state

    /// Windows read from disk, waiting for the app to open them.
    @ObservationIgnored private var pendingWindows: [RestoredWindow] = []
    @ObservationIgnored private(set) var recentlyClosedWindow: PersistedWindow?
    /// A load problem to show in the first window.
    @ObservationIgnored private(set) var loadWarning: String?
    /// False when saved state could not be read: saving would replace it with
    /// this (empty or partial) session, so the session is left unsaved instead.
    @ObservationIgnored private var allowsStateSaving = true
    /// Last-session sidebar counts, round-tripped until the first index publish
    /// (QUA-105): every save before then would otherwise write empty counts.
    @ObservationIgnored private var loadedCountsSnapshot: [EntryType: Int]?
    @ObservationIgnored private var persistenceDepth = 0
    @ObservationIgnored private var persistencePending = false
    @ObservationIgnored private var isRestoring = true

    init(client: VaultClient, stateStore: StateStore? = nil,
         semantic: (any SemanticBackend)? = nil, isFirstRun: Bool = false,
         workspaceRoot: String = "",
         searchDefaults: UserDefaults = .standard,
         readerAIRunner: ReaderAIRunner = ReaderAIRunner()) {
        self.client = client
        self.workspaceRoot = workspaceRoot
        self.isFirstRun = isFirstRun
        self.stateStore = stateStore
        self.semantic = semantic
        self.searchDefaults = searchDefaults
        self.readerAIRunner = readerAIRunner
        self.metadataWriter = MetadataWriter(client: client)
        self.sessionWriter = workspaceRoot.isEmpty ? nil : SessionWriter(workspaceRoot: workspaceRoot)
        self.notes = NoteDraftStore(client: client, catalog: catalog)
        let loaded = stateStore?.loadResult()
        allowsStateSaving = loaded?.allowsSaving ?? true
        if let s = loaded?.state {
            if let restored = s.counts {
                catalog.seedCounts(restored)
                loadedCountsSnapshot = restored
            }
            savedViews = s.savedViews ?? []
            var session = s.restoredSession()
            // Older versions kept temporary tabs per window. Preserve their union
            // before presenting the same set in every restored window.
            if !session.windows.isEmpty {
                var shared = session.windows[0].spaces
                for window in session.windows.dropFirst() {
                    for index in shared.indices {
                        guard let other = window.spaces.first(where: { $0.id == shared[index].id })?.workspace else { continue }
                        var workspace = shared[index].workspace ?? Workspace()
                        workspace.mergeTemporaryTabs(from: other)
                        shared[index].workspace = workspace.isEmpty ? nil : workspace
                    }
                }
                for index in session.windows.indices {
                    for spaceIndex in session.windows[index].spaces.indices {
                        let id = session.windows[index].spaces[spaceIndex].id
                        guard let workspace = shared.first(where: { $0.id == id })?.workspace else { continue }
                        var local = session.windows[index].spaces[spaceIndex].workspace ?? Workspace()
                        local.adoptTabs(from: workspace)
                        session.windows[index].spaces[spaceIndex].workspace = local.isEmpty ? nil : local
                    }
                }
            }
            spaceDefinitions = session.definitions
            pendingWindows = session.windows
            recentlyClosedWindow = s.recentlyClosedWindow
        }
        loadTypeOrder()
        loadHiddenTypes()
        if let loaded, loaded.hadErrors {
            let backup = loaded.backupURL?.path ?? String(localized: "（备份失败）")
            loadWarning = loaded.allowsSaving
                ? String(localized: "部分空间或页面无法读取，已跳过。原始数据备份：\(backup)")
                : String(localized: "无法读取已保存的空间，本次不会保存改动。原始数据备份：\(backup)")
        }
        isRestoring = false
    }

    /// The next saved window to reopen, if any.
    func takeRestoredWindow() -> RestoredWindow? {
        pendingWindows.isEmpty ? nil : pendingWindows.removeFirst()
    }

    /// The load warning, once.
    func takeLoadWarning() -> String? {
        defer { loadWarning = nil }
        return loadWarning
    }

    func register(_ window: AppModel) {
        windowRefs.append(WeakModel(value: window))
        if recentlyClosedWindow?.id == window.windowID { recentlyClosedWindow = nil }
        if spaceDefinitions.isEmpty {
            spaceDefinitions = window.spaces.map(\.definition)
        }
        persist()
    }

    /// A window closed: remember it for reopening from the Dock, then stop
    /// treating it as open. Not called when the app quits with windows open.
    func windowDidClose(_ window: AppModel) {
        recentlyClosedWindow = window.persistedWindow(cache: titleCache)
        unregister(window)
    }

    /// Live title/type for a saved page, from the current index.
    private var titleCache: (NavLocation) -> (title: String?, type: EntryType?) {
        let catalog = catalog
        return { location in
            let entry = catalog.entry(at: location.openPath)
            return (entry?.title, entry?.type)
        }
    }

    /// The last closed window, laid over the current shared definitions.
    func takeRecentlyClosedWindow() -> RestoredWindow? {
        defer { recentlyClosedWindow = nil }
        return recentlyClosedWindow?.restored(over: spaceDefinitions)
    }

    /// Open windows' AppKit side: create a window (nil source = fresh, else a
    /// window cloned from `source`'s Space and browse controls). Set by the app.
    @ObservationIgnored var openWindow: ((_ source: AppModel?) -> AppModel?)?

    func unregister(_ window: AppModel) {
        windowRefs.removeAll { $0.value == nil || $0.value === window }
        undoManager.removeAllActions(withTarget: window)
        notes.release(window)
        window.viewport.cancel()
        persist()
    }

    /// Prevent changes applied to another window from echoing back to the source.
    @ObservationIgnored private var isSharingSpaces = false

    /// Share Space and tab organization while each window keeps its reading state.
    func windowDidChangeSpaces(_ source: AppModel, previous: [WorkspaceSpace]) {
        guard !isSharingSpaces else { return }
        guard windowRefs.contains(where: { $0.value === source }) else { return }
        let definitions = source.spaces.map(\.definition)
        let oldStructure = previous.map { $0.workspace?.sharedTabStructure }
        let newStructure = source.spaces.map { $0.workspace?.sharedTabStructure }
        guard definitions != spaceDefinitions || oldStructure != newStructure else { return }
        spaceDefinitions = definitions
        isSharingSpaces = true
        defer { isSharingSpaces = false }
        for window in windows where window !== source {
            window.adoptSharedSpaces(source.spaces)
        }
    }

    /// Finish synchronous state changes before saving; never span a document read.
    func withPersistenceBatch(_ update: () -> Void) {
        persistenceDepth += 1
        defer {
            persistenceDepth -= 1
            if persistenceDepth == 0, persistencePending {
                persistencePending = false
                persist()
            }
        }
        update()
    }

    /// Save shared definitions once and each open window's reading state, and
    /// mirror the open pages for the iOS companion.
    func persist() {
        guard !isRestoring, allowsStateSaving, let stateStore else { return }
        guard persistenceDepth == 0 else {
            persistencePending = true
            return
        }
        let cache = titleCache
        let ordered = orderedWindows
        // Mirror every Space's pinned forest plus every window's temporary pages to
        // the synced folder for the iOS companion (debounced + dedup'd in the
        // writer). Archived Spaces stay out of the iOS "Mac 上打开的" list.
        sessionWriter?.publish(spaces: SessionWriter.mirror(
            definitions: spaceDefinitions.filter { !$0.isArchived },
            windows: windows.map(\.spaces),
            front: ordered.first.map(\.spaces),
            cache: cache))
        // During bootstrap, write back the loaded counts rather than the empty ones.
        let counts = isBootstrapping ? loadedCountsSnapshot : catalog.counts
        stateStore.save(PersistedState(
            definitions: spaceDefinitions,
            windows: ordered.map { $0.persistedWindow(cache: cache) },
            recentlyClosedWindow: recentlyClosedWindow,
            counts: counts,
            savedViews: savedViews,
            cache: cache))
    }

    // MARK: type order / hidden types persistence

    private static let typeOrderKey = "marple.typeOrder"
    private static let hiddenTypesKey = "marple.hiddenTypes"

    private func loadTypeOrder() {
        guard let data = UserDefaults.standard.data(forKey: Self.typeOrderKey),
              let decoded = try? JSONDecoder().decode([EntryType].self, from: data) else { return }
        // Drop any persisted types no longer modeled as browse categories (e.g.
        // a `transcript` saved by an earlier build), then append new modeled types.
        var order = decoded.filter { EntryType.modeled.contains($0) }
        for t in EntryType.modeled where !order.contains(t) { order.append(t) }
        typeOrder = order
    }

    private func persistTypeOrder() {
        guard let data = try? JSONEncoder().encode(typeOrder) else { return }
        UserDefaults.standard.set(data, forKey: Self.typeOrderKey)
    }

    private func loadHiddenTypes() {
        guard let data = UserDefaults.standard.data(forKey: Self.hiddenTypesKey),
              let decoded = try? JSONDecoder().decode(Set<EntryType>.self, from: data) else { return }
        hiddenTypes = decoded.intersection(EntryType.modeled)
    }

    private func persistHiddenTypes() {
        guard let data = try? JSONEncoder().encode(hiddenTypes) else { return }
        UserDefaults.standard.set(data, forKey: Self.hiddenTypesKey)
    }

    // MARK: index pipeline

    func beginRefreshing() { refreshingCount += 1 }
    func endRefreshing() { refreshingCount = max(0, refreshingCount - 1) }

    func recordIndexFailure(_ error: any Error, context: String) {
        let detail = String(describing: error)
        let message = String(localized: "\(context)：\(detail)")
        lastIndexFailure = message
        status = message
    }

    /// Index-wide caches changed outside a refresh (optimistic edits): rebuild them
    /// and refresh every other window's list (`source` refreshes its own).
    func rebuildIndexDerived(except source: AppModel? = nil) {
        catalog.rebuildIndexDerived(savedViews: savedViews)
        for window in windows where window !== source { window.indexDidChange() }
    }

    /// One reconcile→reload pass — the body every `catalog.refresh` runner executes
    /// (watcher signal, trailing rerun, CLI self-heal). `myPass` is the current
    /// refresh generation, threaded into loadIndex for stale-publish dropping.
    /// No-op when no indexer is wired (stub-backed tests).
    func refreshBody(_ myPass: Int) async {
        termIndexController?.scheduleRefresh()
        guard !archiveCollectionBusy, let indexer = cliIndexer else { return }
        beginRefreshing()
        defer { endRefreshing() }
        let stats: ReconcileStats?
        do { stats = try await Task.detached { try indexer.reconcile() }.value }
        catch {
            recordIndexFailure(error, context: String(localized: "增量更新失败"))
            print("[marple] reconcile failed: \(error)")
            stats = nil
        }
        guard !archiveCollectionBusy else { return }
        await reloadArchiveCollections()
        // A watcher may already have reconciled a collection move while UI
        // publication was suppressed. A zero-change pass still owes a reload.
        guard let stats, archiveCollectionNeedsIndexReload || stats.upserted + stats.removed > 0 else { return }
        await loadIndex(pass: myPass)
        await reloadOpenDocuments()
    }

    func reloadOpenDocuments() async {
        for window in windows { await window.reloadOpen() }
    }

    /// User-initiated recovery for the ordinary SQLite index. `buildFull` writes
    /// a temporary DB and publishes it in a SQLite transaction, so a failed
    /// rebuild leaves the previous readable index intact.
    func rebuildGeneralIndex() async -> GeneralIndexRebuildResult {
        guard !isRebuildingGeneralIndex else { return .alreadyRunning }
        guard let indexer = cliIndexer else { return .unavailable }

        isRebuildingGeneralIndex = true
        status = String(localized: "正在清除并重建普通索引…")
        defer { isRebuildingGeneralIndex = false }

        do {
            let count = try await Task.detached { try indexer.buildFull() }.value
            lastIndexFailure = nil
            await loadIndex()
            if let failure = lastIndexFailure { return .failure(failure) }
            return .success(count)
        } catch {
            recordIndexFailure(error, context: String(localized: "完整重建失败"))
            return .failure(lastIndexFailure ?? String(describing: error))
        }
    }

    /// See `AppModel.loadIndex()`: staleness is the Catalog's per-pass generation;
    /// standalone callers take a fresh pass.
    func loadIndex() async {
        await loadIndex(pass: catalog.beginStandalonePass())
    }

    func loadIndex(pass myPass: Int) async {
        let fetched: [Entry]
        do {
            fetched = try await client.index()
        } catch {
            // Only the latest call publishes failure state — an older stale
            // failure shouldn't clobber a newer call's "n entries" status.
            if !catalog.isStale(myPass) {
                recordIndexFailure(error, context: String(localized: "读取索引失败"))
                status = String(localized: "读取索引失败：\(error)")
                isBootstrapping = false
                print("[marple] index FAILED: \(error)")
            }
            return
        }
        guard !archiveCollectionBusy, catalog.publish(fetched, pass: myPass) else {
            print("[marple] loadIndex pass \(myPass) stale after index() (latest \(catalog.pass)), dropping")
            return
        }
        archiveCollectionNeedsIndexReload = false
        await reloadArchiveCollections()
        isBootstrapping = false
        status = String(localized: "已索引 \(catalog.entries.count) 个条目")
        // Refresh the conformance snapshot on the same cadence as the index. The
        // file is tiny and rarely changes; an absent/stale one simply leaves the
        // feature dark. Loaded here (not watched) since `.quasi/` is a sibling of
        // the watched `vault/` dir.
        schemaSnapshot = SchemaSnapshot.load(workspaceRoot: workspaceRoot)
        VaultSchema.active = VaultSchema.load(workspaceRoot: workspaceRoot)
        // 译本 index — same cadence/rationale as the schema snapshot above.
        localisation = CnDoubanIndex.load(workspaceRoot: workspaceRoot)
        catalog.rebuildIndexDerived(savedViews: savedViews)
        for window in windows { window.indexDidChange() }
        // QUA-105: explicitly persist right after the first snapshot publishes, so
        // live titles/counts round-trip even in a "boot and quit" session.
        persist()
        for window in windows {
            await window.loadDocumentIfStale()
            guard !catalog.isStale(myPass) else {
                print("[marple] loadIndex pass \(myPass) stale after loadDoc, dropping trash refresh")
                return
            }
        }
        // Inline the trash fetch so the publish point is guarded against a newer
        // loadIndex (the public `loadTrash()` is also called from user actions).
        do {
            let trash = try await client.listTrash()
            guard !catalog.isStale(myPass) else {
                print("[marple] loadIndex pass \(myPass) stale after listTrash, dropping trash result")
                return
            }
            trashItems = trash
        } catch {
            print("[marple] listTrash FAILED: \(error)")
        }
        print("[marple] index loaded: \(catalog.entries.count) entries (pass \(myPass))")
    }

    func loadTrash() async {
        do { trashItems = try await client.listTrash() }
        catch { print("[marple] listTrash FAILED: \(error)") }
    }

    func reloadArchiveCollections() async {
        let store = ArchiveCollections(workspaceRoot: workspaceRoot)
        do {
            let inventory = try await Task.detached { try store.inventory() }.value
            archiveCollections = inventory.collections
            archiveCollectionError = inventory.issues.isEmpty ? nil : inventory.issues.joined(separator: "\n")
            let paths = Set(archiveCollections.map(\.path))
            for window in windows { window.expandedArchiveCollections.formIntersection(paths) }
        } catch { archiveCollectionError = String(describing: error) }
    }
}

private struct WeakModel {
    weak var value: AppModel?
}
