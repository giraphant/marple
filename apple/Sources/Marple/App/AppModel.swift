import Foundation
import MarpleKit
import Observation

/// Middle-column display mode for the entry list.
enum BrowseMode: String, CaseIterable, Sendable { case list, grid }

/// Save lifecycle for the note card expanded in the right Inspector.
enum InspectorNoteStatus: Equatable {
    case idle
    case loading
    case dirty
    case saving
    case saved
    case failed(String)
}

enum GeneralIndexRebuildResult: Equatable {
    case success(Int)
    case failure(String)
    case alreadyRunning
    case unavailable
}

@Observable @MainActor
final class AppModel {
    let client: VaultClient
    /// Facade onto the Catalog-owned snapshot (QUA-229: `entries` now lives in the
    /// L2 派生 owner). Read-only here — writes go through `catalog.publish` (refresh
    /// path) / `catalog.mutateEntries` (optimistic edits). All `model.entries` call
    /// sites stay unchanged, like the `counts`/`visibleEntries` facades below.
    var entries: [Entry] { catalog.entries }
    var status: String = ""
    private(set) var lastIndexFailure: String?
    private(set) var isRebuildingGeneralIndex = false

    /// Workspace root (parent of `vault/`). Used only to locate the optional
    /// `.quasi/schema.json` conformance snapshot. Empty in stub-backed tests.
    let workspaceRoot: String

    /// The vault indexer, injected at boot. Lets the CLI surface self-heal the
    /// FSEvents watcher race: when an agent writes a vault file and immediately
    /// calls `open`/`read`/`search`, the 0.4s-debounced watcher hasn't reconciled
    /// yet, so the just-written file is absent from `entries`/the index. The CLI
    /// handlers trigger a synchronous reconcile through this. nil in stub tests.
    var cliIndexer: VaultIndexer?

    /// L2 编目层派生状态 owner (QUA-218 PR3a). 持全部派生缓存 + vault-变更管线的
    /// 统一 generation/单飞权威 (QUA-198/QUA-212 的 RefreshAuthority 合流单飞 +
    /// loadIndex staleness 2→1)，经 catalog.refresh/refreshJoining 暴露唯一入口。
    let catalog = Catalog()

    /// The vault's self-describing schema snapshot, reloaded on every index load.
    /// nil when the vault has no `.quasi/schema.json` (or it's stale/unreadable) —
    /// in which case the conformance feature stays dark. See [[SchemaSnapshot]].
    private(set) var schemaSnapshot: SchemaSnapshot?

    /// The vault's Chinese-translation index (`.quasi/localise/cndouban.json`),
    /// reloaded on every index load. nil when the sidecar is absent/unreadable —
    /// the 译本 inspector row then stays dark. See [[CnDoubanIndex]].
    private(set) var localisation: CnDoubanIndex?

    /// Required-field conformance for one entry, or nil when the vault has no
    /// schema opinion on it (no snapshot, or an unmodeled type). Read-only,
    /// auxiliary: callers that get nil render exactly as before.
    func conformance(for entry: Entry) -> ConformanceResult? {
        guard let snapshot = schemaSnapshot else { return nil }
        return VaultConformance.check(entry, against: snapshot)
    }

    /// True until the first `loadIndex()` either publishes a snapshot or
    /// reports an error. Stays false for the rest of the session — subsequent
    /// reloads from the watcher / deferred reconcile / user refresh don't flip
    /// it back. Views read this to distinguish "still booting, show skeleton"
    /// from "loaded but empty vault, show empty state" (QUA-105). The bare
    /// `entries.isEmpty` check those views used before was ambiguous between
    /// the two and would have rendered drop-zones during cold start.
    private(set) var isBootstrapping: Bool = true

    /// True when this session has no reusable index sidecar.
    let isFirstRun: Bool

    /// True while a post-bootstrap background reconcile + reload is running
    /// (deferred reconcile on the fast path, FSEvents watcher, future user-
    /// triggered refresh). Counter-backed so two reconciles overlapping don't
    /// race the future refresh affordance off and on.
    private var refreshingCount: Int = 0
    var isRefreshing: Bool { refreshingCount > 0 }
    func beginRefreshing() { refreshingCount += 1 }
    func endRefreshing() { refreshingCount = max(0, refreshingCount - 1) }

    /// One reconcile→reload pass — the body every `catalog.refresh` runner executes
    /// (watcher signal, trailing rerun, CLI self-heal). `myPass` is the current
    /// refresh generation, threaded into loadIndex for stale-publish dropping.
    /// No-op when no indexer is wired (stub-backed tests).
    func refreshBody(_ myPass: Int) async {
        guard let indexer = cliIndexer else { return }
        beginRefreshing()
        defer { endRefreshing() }
        let stats: ReconcileStats?
        do { stats = try await Task.detached { try indexer.reconcile() }.value }
        catch {
            recordIndexFailure(error, context: String(localized: "增量更新失败"))
            print("[marple] reconcile failed: \(error)")
            stats = nil
        }
        guard let stats, stats.upserted + stats.removed > 0 else { return }
        await loadIndex(pass: myPass)
        await reloadOpen()
    }

    /// User-initiated recovery for the ordinary SQLite index. `buildFull` writes
    /// a temporary DB and atomically swaps it over the live file, so a failed
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

    func recordIndexFailure(_ error: any Error, context: String) {
        let detail = String(describing: error)
        let message = String(localized: "\(context)：\(detail)")
        lastIndexFailure = message
        status = message
    }

    var generalIndexStatusDescription: String {
        var lines = [
            String(localized: "普通索引包含 \(entries.count) 个条目。"),
            isRebuildingGeneralIndex
                ? String(localized: "状态：正在清除并重建。")
                : String(localized: "状态：\(status.isEmpty ? String(localized: "就绪") : status)")
        ]
        if let lastIndexFailure {
            lines.append(String(localized: "\n最近一次索引障碍：\n\(lastIndexFailure)"))
        } else {
            lines.append(String(localized: "\n当前没有已知的索引障碍。重复的 themes 条目会自动去重。"))
        }
        return lines.joined(separator: "\n")
    }

    /// Card grid vs single-column list. Pure UI toggle; no derived cache depends on it.
    var browseMode: BrowseMode = .grid { didSet { persist() } }

    // Browse axis: which category list the sidebar shows. Separate from tabs —
    // selecting a category never touches the open document tabs.
    private(set) var browsePane: Pane = .type(.paper) { didSet { persist() } }

    // Arc-style Spaces: each Space owns an independent document-tab workspace.
    // The computed workspace/isBrowsing properties below preserve the previous
    // single-workspace call sites by pointing them at the active Space.
    private(set) var spaces: [WorkspaceSpace] = [] { didSet { persist() } }
    private(set) var activeSpaceID: WorkspaceSpace.ID? { didSet { persist() } }

    private var activeSpaceIndex: Int? {
        guard let activeSpaceID else { return spaces.indices.first }
        return spaces.firstIndex { $0.id == activeSpaceID }
    }

    var activeSpace: WorkspaceSpace? {
        activeSpaceIndex.map { spaces[$0] }
    }

    // Browsing the category list (true) vs reading an open document tab (false),
    // scoped to the active Space.
    private(set) var isBrowsing: Bool {
        get { activeSpaceIndex.map { spaces[$0].isBrowsing } ?? true }
        set {
            guard let index = activeSpaceIndex else { return }
            spaces[index].isBrowsing = newValue
        }
    }

    // Open DOCUMENT tabs (browser-style), nil until the first doc is opened and back
    // to nil when the last closes. Each tab carries its own back/forward history
    // (e.g. following wikilinks). Categories are NOT tabs. Scoped to the active Space.
    private(set) var workspace: Workspace? {
        get { activeSpaceIndex.flatMap { spaces[$0].workspace } }
        set {
            guard let index = activeSpaceIndex else { return }
            spaces[index].workspace = newValue
        }
    }

    var pane: Pane {
        guard !isBrowsing else { return browsePane }
        return workspace?.activeTab.location.pane ?? browsePane
    }
    var openPath: String? { isBrowsing ? nil : workspace?.activeTab.location.openPath }
    var tabs: [NavTab] { workspace?.tabs ?? [] }
    var tabGroups: [TabGroup] { workspace?.tabGroups ?? [] }
    var tabRootNodes: [TabNode] { workspace?.rootNodes ?? [] }
    var activeTabID: NavTab.ID? { isBrowsing ? nil : workspace?.activeID }
    var canGoBack: Bool { !isBrowsing && (workspace?.activeTab.history.canGoBack ?? false) }
    var canGoForward: Bool { !isBrowsing && (workspace?.activeTab.history.canGoForward ?? false) }
    var isPinnedListContext: Bool { !isBrowsing && (workspace?.activeTab.pinned ?? false) }

    /// Mutate the active Space's optional doc-tab workspace in place (struct value semantics).
    private func mutateWorkspace(_ f: (inout Workspace) -> Void) {
        guard var ws = workspace else { return }
        f(&ws)
        workspace = ws.isEmpty ? nil : ws
    }

    // The doc whose body/blocks/derived caches are currently loaded — lets tab and
    // history switches skip a re-fetch when the doc hasn't actually changed.
    private var loadedDocPath: String?

    // Browse state (mutate via the intent methods below so derived caches refresh)
    private(set) var sortClauses: [SortClause] = [] { didSet { persist() } }
    private(set) var filterClauses: [FilterClause] = [] { didSet { persist() } }
    private(set) var filterMatch: FilterMatch = .all { didSet { persist() } }

    // Saved smart-folder views (QUA-127). Each carries its own filter+sort,
    // edited write-through while browsing it; the global clauses above belong
    // to the type/theme buckets and are untouched by view edits (拍板: 视图自带、桶用全局).
    private(set) var savedViews: [SavedView] = [] {
        didSet {
            persist()
            catalog.recomputeSavedViewCounts(savedViews: savedViews)
        }
    }
    /// Live row counts per saved view for the sidebar (computed like the type
    /// bucket counts, over the browse universe).
    var savedViewCounts: [UUID: Int] { catalog.savedViewCounts }

    func savedView(_ id: UUID) -> SavedView? { savedViews.first { $0.id == id } }

    /// The filter/sort the CURRENT pane uses: a saved view's own definition
    /// while browsing one, the global browse controls otherwise. All UI
    /// (popovers, button states) and the list pipeline read these.
    var activeFilterClauses: [FilterClause] {
        if case .savedView(let id) = pane, let v = savedView(id) { return v.clauses }
        return filterClauses
    }
    var activeFilterMatch: FilterMatch {
        if case .savedView(let id) = pane, let v = savedView(id) { return v.match }
        return filterMatch
    }
    var activeSortClauses: [SortClause] {
        if case .savedView(let id) = pane, let v = savedView(id) { return v.sorts }
        return sortClauses
    }
    private(set) var searchText: String = ""
    private var searchHits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?

    /// Per-result matched body lines for the current list search (keyed by path).
    /// Populated off-main after the search settles; rows read from it.
    var searchMatches: [String: BodyMatches] { catalog.searchMatches }
    /// The query `searchMatches` was computed for. A matched-line tap uses THIS
    /// (not the live `searchText`) so a tap during the debounce window stays
    /// self-consistent — anchor/ordinal/query always describe the same search.
    var searchMatchQuery: String { catalog.searchMatchQuery }
    /// Result rows whose "再显示 N 个匹配项" expander has been opened.
    var matchExpanded: Set<String> { catalog.matchExpanded }

    // Derived caches — recomputed only when their inputs change, never in a view body.
    var counts: [EntryType: Int] { catalog.counts }
    var themeIndex: [ThemeCount] { catalog.themeIndex }
    var topicMembership: TopicMembership { catalog.topicMembership }
    var visibleEntries: [Entry] {
        guard isPinnedListContext else { return catalog.visibleEntries }
        var order: [String: Int] = [:]
        for tab in tabs where tab.pinned {
            if let path = tab.location.openPath, order[path] == nil { order[path] = order.count }
        }
        let source = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? entries : searchHits.map(\.entry)
        return source.compactMap { entry in order[entry.path].map { ($0, entry) } }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }
    var relationGraph: RelationGraph { catalog.relationGraph }
    /// Prebuilt field-weighted index for the command palette's 快速 mode (rebuilt
    /// whenever `entries` changes, like the other derived caches). Carries a
    /// trigram inverted index so per-keystroke ranking only scores hundreds of
    /// candidate docs instead of 15k full-scans.
    var searchIndex: SearchIndex { catalog.searchIndex }

    // Trash list (loaded lazily; sidebar badge reads .count).
    private(set) var trashItems: [TrashItem] = []

    // Reading state
    var openBlocks: [RenderBlock] = []

    // Open-doc derived caches now live in Catalog (QUA-218 PR3a Task 5); facade
    // forwarders so views keep reading `model.X`. `openBody` stays here — it's the
    // loaded text set by loadDoc and an INPUT to recomputeOpenDerived.
    private(set) var openBody: String = ""
    var openEntry: Entry? { catalog.openEntry }
    var openOutline: [OutlineItem] { catalog.openOutline }
    var openStats: DocStats? { catalog.openStats }
    var openRelations: Relations? { catalog.openRelations }
    var openBook: BookContext? { catalog.openBook }
    var openTopic: TopicContext? { catalog.openTopic }

    // Inspector note editor state. This is intentionally separate from `openPath`:
    // selecting a note in the right rail must not replace the document in the reader.
    private(set) var inspectorSelectedNotePath: String?
    private(set) var inspectorSelectedNoteEntry: Entry?
    private(set) var inspectorNoteDraft: String = ""
    private(set) var inspectorNoteOriginal: String = ""
    private(set) var inspectorNoteStatus: InspectorNoteStatus = .idle
    private(set) var inspectorNoteDrafts: [String: String] = [:]
    private var inspectorNoteOriginals: [String: String] = [:]
    private(set) var inspectorNoteStatuses: [String: InspectorNoteStatus] = [:]
    var inspectorNoteHeights: [String: Double] = [:]
    var inspectorFocusedNotePath: String?
    @ObservationIgnored private var inspectorNoteSaveTask: Task<Void, Never>?
    @ObservationIgnored private var inspectorNoteSaveTasks: [String: Task<Void, Never>] = [:]

    var inspectorAnnotationNotes: [Entry] {
        var notes = (openRelations?.annotations ?? []).sorted(by: inspectorNoteComesBefore)
        if let selected = inspectorSelectedNoteEntry,
           selected.annotates == openEntry.map({ annotationTarget(for: $0, in: entries).path }),
           !notes.contains(where: { $0.path == selected.path }) {
            notes.append(selected)
        }
        return notes
    }

    var canCreateInlineAnnotationForOpenDoc: Bool {
        openEntry != nil && inspectorAnnotationNotes.allSatisfy { note in
            guard let draft = inspectorNoteDrafts[note.path] else { return true }
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // Inspector → reader scroll channel; an outline tap sets this, DocView observes.
    var scrollTarget: Int?

    /// Query whose matches are highlighted in the open document. Set when a search
    /// matched-line is clicked; cleared on any other navigation.
    private(set) var openSearchQuery: String?

    /// One-shot "scroll to this match" request for the reader. `anchor` (the line's
    /// plain text) locates the exact spot in the rendered text; `ordinal` is the
    /// fallback; `id` lets re-clicking the same line re-fire the scroll.
    struct MatchJump: Equatable {
        let id = UUID()
        let query: String
        let anchor: String
        let ordinal: Int
    }
    private(set) var matchJump: MatchJump?

    /// Right inspector visibility. Lives here (not as view @State) so the AppKit
    /// toolbar's far-right toggle can drive it while SwiftUI's `.inspector` observes.
    var inspectorVisible = true

    /// Transient confirmation shown briefly over the reader (e.g. "已复制引用"), since
    /// a copy/placeholder action otherwise gives no visible signal. DocView renders it.
    struct Toast: Equatable { let id = UUID(); var text: String; var symbol: String }
    var toast: Toast?
    func flash(_ text: String, symbol: String = "checkmark.circle.fill") {
        toast = Toast(text: text, symbol: symbol)
    }

    /// Active talk/transcript media playback. Non-nil presents the lightweight
    /// player sheet; `seekToken` changes on every timestamp click so the player
    /// re-seeks without re-presenting. Cleared when the player is closed.
    struct TalkPlayback: Equatable {
        let mediaURL: URL
        let subtitlesURL: URL?
        let title: String
        var seconds: Double
        var seekToken = UUID()
    }
    private(set) var talkPlayback: TalkPlayback?

    /// Open (or re-seek) the player for the current talk/transcript at `seconds`.
    /// No-op with a toast when the gitignored recording is absent on this machine.
    func playTalk(seconds: Double) {
        guard let entry = openEntry,
              entry.type == .talk || entry.type == .transcript,
              let media = client.talkMediaURL(forEntryPath: entry.path) else {
            flash(String(localized: "录制文件不存在"), symbol: "exclamationmark.triangle.fill")
            return
        }
        let title = entry.title ?? (entry.path as NSString).lastPathComponent
        if var pb = talkPlayback, pb.mediaURL == media {
            pb.seconds = seconds
            pb.seekToken = UUID()
            talkPlayback = pb
        } else {
            talkPlayback = TalkPlayback(
                mediaURL: media,
                subtitlesURL: client.talkSubtitlesURL(forEntryPath: entry.path),
                title: title,
                seconds: seconds)
        }
    }

    func closeTalkPlayback() { talkPlayback = nil }

    // Metadata write state.
    private(set) var savingField: String?
    var writeError: String?

    private let stateStore: StateStore?
    private var semantic: (any SemanticBackend)?
    private let readerAIRunner: ReaderAIRunner
    /// Publishes open tabs to the synced folder for the iOS companion. nil without
    /// a workspace root (e.g. tests).
    private let sessionWriter: SessionWriter?
    private let metadataWriter: MetadataWriter

    /// True when the vector index and MLX runtime are present, so 深度 can run.
    var semanticAvailable: Bool { semantic != nil }

    func installSemanticBackend(_ semantic: (any SemanticBackend)?) {
        self.semantic = semantic
    }

    /// User-customised sidebar type order. Defaults to the canonical order; persisted
    /// separately from workspace state via UserDefaults.
    private(set) var typeOrder: [EntryType] = EntryType.modeled {
        didSet { persistTypeOrder() }
    }

    /// Sidebar-hidden type buckets (QUA-127). Display-only: ⌘T, search, open tabs
    /// and saved views still reach a hidden type's entries — only the 物件 row
    /// disappears. Persisted like `typeOrder`, separate from workspace state.
    private(set) var hiddenTypes: Set<EntryType> = [] {
        didSet { persistHiddenTypes() }
    }

    /// The type buckets the sidebar actually shows, in user order.
    var visibleTypeOrder: [EntryType] { typeOrder.filter { !hiddenTypes.contains($0) } }

    init(client: VaultClient, stateStore: StateStore? = nil,
         semantic: (any SemanticBackend)? = nil, isFirstRun: Bool = false,
         workspaceRoot: String = "",
         readerAIRunner: ReaderAIRunner = ReaderAIRunner()) {
        self.client = client
        self.metadataWriter = MetadataWriter(client: client)
        self.workspaceRoot = workspaceRoot
        self.stateStore = stateStore
        self.semantic = semantic
        self.readerAIRunner = readerAIRunner
        self.sessionWriter = workspaceRoot.isEmpty ? nil : SessionWriter(workspaceRoot: workspaceRoot)
        self.isFirstRun = isFirstRun
        if let s = stateStore?.load() {
            // QUA-105: seed `loadedCountsSnapshot` BEFORE the property setters
            // below trigger `persist()` via didSet. Otherwise the first persist
            // (from `browsePane = ...`) writes `counts: nil` back to disk,
            // wiping the user's restored type counts before we'd had a chance
            // to round-trip them.
            if let restored = s.counts {
                catalog.seedCounts(restored)
                loadedCountsSnapshot = restored
            }
            // Restore views BEFORE browsePane: its didSet persists, and a
            // .savedView pane needs the list present to resolve (same ordering
            // discipline as the counts snapshot above).
            savedViews = s.savedViews ?? []
            browsePane = s.browsePane
            // A stale .savedView reference (view deleted, blob raced) degrades
            // to the first bucket instead of an unfiltered everything-list.
            if case .savedView(let id) = browsePane, savedView(id) == nil {
                browsePane = .type(.paper)
            }
            let restoredSpaces = s.makeSpaces()
            spaces = restoredSpaces.spaces
            activeSpaceID = restoredSpaces.activeID
            if workspace == nil { isBrowsing = true }
            if !isBrowsing, workspace?.activeTab.pinned == false {
                searchText = workspace?.activeTab.location.searchText ?? ""
            }
            sortClauses = s.sortClauses
            filterClauses = s.filterClauses
            filterMatch = s.filterMatch
            browseMode = BrowseMode(rawValue: s.browseMode) ?? .grid
        }
        if spaces.isEmpty {
            let initial = WorkspaceSpace(name: String(localized: "空间 1"), workspace: nil, isBrowsing: true)
            spaces = [initial]
            activeSpaceID = initial.id
        }
        loadTypeOrder()
        loadHiddenTypes()
    }

    /// Last-session sidebar counts, restored from PersistedState in init. Kept
    /// so `persist()` can round-trip them during the bootstrap window — without
    /// this, every persist before the first loadIndex would overwrite the
    /// stored counts with an empty `[:]` (because didSet on browsePane etc.
    /// fires during AppModel.init, well before entries are loaded). Once
    /// bootstrap completes, the live `counts` is authoritative. QUA-105.
    private var loadedCountsSnapshot: [EntryType: Int]?

    /// Save the current place (browse category + Spaces + doc tabs + controls). Cheap —
    /// a small JSON blob to UserDefaults; invoked from state properties' didSet.
    private func persist() {
        guard let stateStore else { return }
        let liveByPath: [String: Entry] = Dictionary(
            entries.lazy.compactMap { e -> (String, Entry)? in (e.path, e) },
            uniquingKeysWith: { a, _ in a })
        func persistedTab(_ tab: NavTab) -> PersistedTab {
            // Title + type snapshot: prefer the live entry; if entries haven't
            // loaded (bootstrap window) or the path no longer resolves (file
            // was deleted), carry over whatever we previously cached so the
            // next launch's sidebar still shows the right title AND the right
            // type icon. Falls to nil only if no source has ever produced one.
            let liveEntry = tab.location.openPath.flatMap { liveByPath[$0] }
            let cachedTitle = liveEntry?.title ?? tab.cachedTitle
            let cachedType = liveEntry?.type ?? tab.cachedType
            return PersistedTab(location: tab.location, pinned: tab.pinned,
                                customTitle: tab.customTitle,
                                cachedTitle: cachedTitle,
                                cachedType: cachedType)
        }
        let savedSpaces = spaces.map { space -> PersistedWorkspaceSpace in
            let ws = space.workspace
            let savedTabs = ws?.tabs.map(persistedTab) ?? []
            let idx = ws.flatMap { w in w.tabs.firstIndex { $0.id == w.activeID } } ?? 0
            return PersistedWorkspaceSpace(id: space.id,
                                           name: space.name,
                                           isBrowsing: ws == nil ? true : space.isBrowsing,
                                           tabs: savedTabs,
                                           activeIndex: idx,
                                           iconName: space.iconName,
                                           isArchived: space.isArchived,
                                           tree: ws?.treeSnapshot)
        }
        let activeSavedSpace = activeSpaceID.flatMap { id in savedSpaces.first { $0.id == id } } ?? savedSpaces.first
        // Mirror every Space's open tab forest (names + icons + groups + nesting) to
        // the synced folder for the iOS companion (debounced + dedup'd in the writer).
        // Archived Spaces stay out of the iOS "Mac 上打开的" list.
        sessionWriter?.publish(spaces: savedSpaces.filter { !$0.isArchived })
        // Same round-trip discipline for counts — during bootstrap, write back
        // the loaded snapshot rather than the still-empty `counts` dict.
        let persistedCounts: [EntryType: Int]? =
            isBootstrapping ? loadedCountsSnapshot : counts
        stateStore.save(PersistedState(
            browsePane: browsePane,
            isBrowsing: activeSavedSpace?.isBrowsing ?? true,
            tabs: activeSavedSpace?.tabs ?? [],
            activeIndex: activeSavedSpace?.activeIndex ?? 0,
            sortClauses: sortClauses,
            filterClauses: filterClauses,
            filterMatch: filterMatch,
            browseMode: browseMode.rawValue,
            currentSpace: activeSavedSpace,
            spaces: savedSpaces,
            activeSpaceID: activeSavedSpace?.id,
            counts: persistedCounts,
            savedViews: savedViews))
    }

    // MARK: type order persistence

    private static let typeOrderKey = "marple.typeOrder"

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

    func setTypeOrder(_ order: [EntryType]) {
        typeOrder = order
    }

    // MARK: hidden types persistence (QUA-127)

    private static let hiddenTypesKey = "marple.hiddenTypes"

    private func loadHiddenTypes() {
        guard let data = UserDefaults.standard.data(forKey: Self.hiddenTypesKey),
              let decoded = try? JSONDecoder().decode(Set<EntryType>.self, from: data) else { return }
        hiddenTypes = decoded.intersection(EntryType.modeled)
    }

    private func persistHiddenTypes() {
        guard let data = try? JSONEncoder().encode(hiddenTypes) else { return }
        UserDefaults.standard.set(data, forKey: Self.hiddenTypesKey)
    }

    func setTypeHidden(_ type: EntryType, hidden: Bool) {
        if hidden {
            hiddenTypes.insert(type)
            // Hiding the bucket being browsed: jump to the first visible bucket
            // so the list doesn't show a category the sidebar no longer offers.
            if case .type(let current) = browsePane, current == type,
               let first = visibleTypeOrder.first {
                select(pane: .type(first))
            }
        } else {
            hiddenTypes.remove(type)
        }
    }

    // MARK: derived recompute

    /// Rebuild the index-wide caches. Split into two phases:
    /// - immediate: counts + themeIndex + topicMembership (cheap; the sidebar and
    ///   open topic pages need them right away)
    /// - deferred: relationGraph/searchIndex (heavy; only needed by
    ///   the reading view's relations panel and the Cmd-K palette, neither of
    ///   which is exercised in the first few hundred ms after launch)
    private func rebuildIndexDerived() {
        catalog.rebuildIndexDerived(savedViews: savedViews)
    }

    /// Recompute the open document's open-doc derived caches. Routes to Catalog;
    /// `openPath`/`openBody`/`openBlocks` are shell inputs (the outline is built
    /// from the font-free `openBlocks`, so no render-style constants cross over).
    private func recomputeOpenDerived() {
        catalog.recomputeOpenDerived(openPath: openPath, openBody: openBody,
                                     openBlocks: openBlocks)
    }

    /// Rebuild the middle-column list. Search hits are a cheap direct swap; the pane
    /// subset (filter→sort over ~15k entries) is computed OFF the main thread and
    /// applied back on main, with stale rebuilds dropped via task cancellation. This
    /// keeps clearing search / switching panes off the keystroke so text input never
    /// blocks — mirrors NetNewsWire/FSNotes/CodeEdit list-search discipline (don't
    /// re-filter synchronously in the input handler).
    private func recomputeVisible() {
        guard !isPinnedListContext else { return }
        catalog.recomputeVisible(searchText: searchText, searchHits: searchHits,
                                 pane: pane, entries: entries,
                                 filters: activeFilterClauses, match: activeFilterMatch,
                                 sorts: activeSortClauses)
    }

    // MARK: actions

    func addSpace() {
        let nextNumber = spaces.count + 1
        let space = WorkspaceSpace(name: String(localized: "空间 \(nextNumber)"), workspace: nil, isBrowsing: true)
        spaces.append(space)
        activeSpaceID = space.id
        isBrowsing = true
        resetSearch(to: "")
        clearReaderHighlight()
        Task { await loadDoc(nil) }
    }

    func selectSpace(_ id: WorkspaceSpace.ID) async {
        guard spaces.contains(where: { $0.id == id }) else { return }
        guard activeSpaceID != id else { return }
        activeSpaceID = id
        if workspace == nil || isBrowsing {
            isBrowsing = true
            resetSearch(to: "")
            clearReaderHighlight()
            await loadDoc(nil)
        } else {
            await syncToActiveLocation()
        }
    }

    /// Open `path` as a document tab in a specific Space (QUA-114, drag a browse
    /// card onto a Space). Dropping on the active Space opens + shows it; dropping
    /// on another Space files it there as a tab without yanking focus.
    func openInSpace(_ path: String, space id: WorkspaceSpace.ID) async {
        if id == activeSpaceID {
            await openNewTab(path)
            return
        }
        let loc = sourceLocation(for: path)
        mutateSpace(id) { space in
            if space.workspace == nil {
                space.workspace = Workspace(initial: loc)
            } else {
                space.workspace?.newTab(loc)
            }
            space.isBrowsing = false
        }
    }

    func moveSpace(from source: IndexSet, to destination: Int) {
        spaces.move(fromOffsets: source, toOffset: destination)
    }

    func moveSpace(_ id: WorkspaceSpace.ID, before targetID: WorkspaceSpace.ID) {
        guard id != targetID,
              let from = spaces.firstIndex(where: { $0.id == id }),
              let to = spaces.firstIndex(where: { $0.id == targetID }) else { return }
        spaces.move(fromOffsets: IndexSet(integer: from), toOffset: to)
    }

    func moveSpace(_ id: WorkspaceSpace.ID, after targetID: WorkspaceSpace.ID) {
        guard id != targetID,
              let from = spaces.firstIndex(where: { $0.id == id }),
              let to = spaces.firstIndex(where: { $0.id == targetID }) else { return }
        spaces.move(fromOffsets: IndexSet(integer: from), toOffset: to + 1)
    }

    func setSpaceIcon(_ iconName: String?, for id: WorkspaceSpace.ID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = iconName?.trimmingCharacters(in: .whitespacesAndNewlines)
        spaces[index].iconName = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Spaces shown in the bottom switcher bar — everything that isn't archived.
    var activeSpaces: [WorkspaceSpace] { spaces.filter { !$0.isArchived } }

    /// Archived Spaces, listed in Settings ▸ Spaces for restore/delete.
    var archivedSpaces: [WorkspaceSpace] { spaces.filter { $0.isArchived } }

    func renameSpace(_ id: WorkspaceSpace.ID, to name: String) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        spaces[index].name = trimmed
    }

    /// Archive a Space: hide it from the switcher but keep its tabs. If it was the
    /// active one, fall back to another visible Space (creating a fresh one when the
    /// last visible Space is archived, so the window always has somewhere to be).
    func archiveSpace(_ id: WorkspaceSpace.ID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }), !spaces[index].isArchived else { return }
        spaces[index].isArchived = true
        if activeSpaceID == id { fallBackToVisibleSpace() }
    }

    func unarchiveSpace(_ id: WorkspaceSpace.ID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }), spaces[index].isArchived else { return }
        spaces[index].isArchived = false
    }

    func deleteSpace(_ id: WorkspaceSpace.ID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeSpaceID == id
        spaces.remove(at: index)
        if wasActive { fallBackToVisibleSpace() }
    }

    /// Point `activeSpaceID` at a visible Space, materialising one if none remain.
    private func fallBackToVisibleSpace() {
        if let next = spaces.first(where: { !$0.isArchived }) {
            Task { await selectSpace(next.id) }
        } else {
            let fresh = WorkspaceSpace(name: String(localized: "空间 \(spaces.count + 1)"), workspace: nil, isBrowsing: true)
            spaces.append(fresh)
            activeSpaceID = fresh.id
            isBrowsing = true
            resetSearch(to: "")
            clearReaderHighlight()
            Task { await loadDoc(nil) }
        }
    }

    private func mutateSpace(_ id: WorkspaceSpace.ID, _ body: (inout WorkspaceSpace) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        var space = spaces[index]
        body(&space)
        if space.workspace?.isEmpty == true {
            space.workspace = nil
            space.isBrowsing = true
        }
        spaces[index] = space
    }

    private func firstMovedTabID(in bundle: WorkspaceTransferBundle) -> NavTab.ID? {
        for node in bundle.nodes {
            switch node {
            case .tab(let id): return id
            case .group(let group):
                if let id = firstTabID(in: group.children) { return id }
            }
        }
        return bundle.tabs.first?.id
    }

    private func firstTabID(in nodes: [TabNode]) -> NavTab.ID? {
        for node in nodes {
            switch node {
            case .tab(let id): return id
            case .group(let group):
                if let id = firstTabID(in: group.children) { return id }
            }
        }
        return nil
    }

    func moveItems(_ items: [WorkspaceItem], from sourceSpaceID: WorkspaceSpace.ID, toRootAt index: Int? = nil) {
        guard activeSpaceID != nil else { return }
        var bundle = WorkspaceTransferBundle(tabs: [], nodes: [])
        mutateSpace(sourceSpaceID) { source in
            guard var ws = source.workspace else { return }
            bundle = ws.extractItemsForTransfer(items)
            source.workspace = ws.isEmpty ? nil : ws
            if source.workspace == nil { source.isBrowsing = true }
        }
        guard !bundle.tabs.isEmpty, let destinationID = activeSpaceID else { return }
        mutateSpace(destinationID) { destination in
            if destination.workspace == nil, let first = bundle.tabs.first {
                var ws = Workspace(initial: first.location)
                _ = ws.extractItemsForTransfer([.tab(ws.activeID)])
                ws.insertTransferBundleToRoot(bundle, at: index)
                destination.workspace = ws
            } else {
                destination.workspace?.insertTransferBundleToRoot(bundle, at: index)
            }
            if let moved = firstMovedTabID(in: bundle) { destination.workspace?.select(moved) }
            destination.isBrowsing = false
        }
    }

    func moveItems(_ items: [WorkspaceItem], from sourceSpaceID: WorkspaceSpace.ID,
                   toGroup groupID: TabGroup.ID, at childIndex: Int? = nil) {
        guard let destinationID = activeSpaceID,
              spaces.first(where: { $0.id == destinationID })?.workspace?.tabGroups.contains(where: { $0.id == groupID }) == true else { return }
        var bundle = WorkspaceTransferBundle(tabs: [], nodes: [])
        mutateSpace(sourceSpaceID) { source in
            guard var ws = source.workspace else { return }
            bundle = ws.extractItemsForTransfer(items)
            source.workspace = ws.isEmpty ? nil : ws
            if source.workspace == nil { source.isBrowsing = true }
        }
        guard !bundle.tabs.isEmpty else { return }
        mutateSpace(destinationID) { destination in
            destination.workspace?.insertTransferBundle(bundle, toGroup: groupID, at: childIndex)
            if let moved = firstMovedTabID(in: bundle) { destination.workspace?.select(moved) }
            destination.isBrowsing = false
        }
    }

    /// `loadIndex()` runs concurrently with itself in practice: the fast-path boot
    /// kicks a deferred reconcile that calls loadIndex on completion, the FSEvents
    /// watcher calls loadIndex on every debounced vault change, and the in-progress
    /// QUA-105 startup flow adds a background "full hydration" path. Staleness is
    /// now the Catalog's unified per-pass generation (QUA-218 2→1): a refresh pass
    /// passes its `myPass` in; standalone callers (restoreTrash, boot first load,
    /// tests) take a fresh pass via `catalog.beginStandalonePass()`. After every
    /// suspension point we recheck `catalog.isStale(myPass)` — if a newer pass has
    /// begun, the older one drops its result instead of overwriting freshly-
    /// published `entries`/`trashItems`. Same shape as `derivedGeneration` in
    /// `scheduleDeferredDerivedRebuild` (which stays its own independent counter).
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
        guard catalog.publish(fetched, pass: myPass) else {
            print("[marple] loadIndex pass \(myPass) stale after index() (latest \(catalog.pass)), dropping")
            return
        }
        isBootstrapping = false
        status = String(localized: "已索引 \(entries.count) 个条目")
        // Refresh the conformance snapshot on the same cadence as the index. The
        // file is tiny and rarely changes; an absent/stale one simply leaves the
        // feature dark. Loaded here (not watched) since `.quasi/` is a sibling of
        // the watched `vault/` dir.
        schemaSnapshot = SchemaSnapshot.load(workspaceRoot: workspaceRoot)
        VaultSchema.active = VaultSchema.load(workspaceRoot: workspaceRoot)
        // 译本 index — same cadence/rationale as the schema snapshot above:
        // a tiny `.quasi/` sidecar, loaded (not watched) since it's a sibling of
        // the watched `vault/` dir and maintained by `quasi-helpers localise`.
        localisation = CnDoubanIndex.load(workspaceRoot: workspaceRoot)
        rebuildIndexDerived()
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            recomputeVisible()
        } else {
            runSearch()
        }
        // QUA-105: explicitly persist right after the first snapshot publishes.
        // `entries` and `counts` are not `didSet`-instrumented (changing them
        // is too hot a path to fire a UserDefaults write on every reload), so
        // a "boot and quit without interaction" session would otherwise never
        // round-trip live titles/counts into PersistedState — defeating the
        // whole point of caching them for next launch's bootstrap window.
        persist()
        if openPath != loadedDocPath {
            await loadDoc(openPath)
            guard !catalog.isStale(myPass) else {
                print("[marple] loadIndex pass \(myPass) stale after loadDoc, dropping trash refresh")
                return
            }
        }
        // Inline the trash fetch instead of `await loadTrash()` so we can guard
        // the publish point against a newer loadIndex (the public `loadTrash()`
        // is also called from user actions where this guard would be wrong).
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
        print("[marple] index loaded: \(entries.count) entries (pass \(myPass))")
    }

    func select(pane newPane: Pane) {
        // Selecting a category switches the browse list ONLY — it never touches the
        // open document tabs (browser-style: the top is navigation, tabs are pages).
        browsePane = newPane
        isBrowsing = true
        searchText = ""; searchHits = []; searchTask?.cancel()
        clearSearchMatches(); clearReaderHighlight()
        recomputeVisible()
        if case .trash = newPane { Task { await loadTrash() } }
        print("[marple] browse -> \(newPane)")
    }

    // Write-through routing (QUA-127 拍板: 直写视图): editing filter/sort while
    // browsing a saved view mutates the view's definition like editing a
    // document; in a bucket it edits the global controls as before.
    func setSort(_ clauses: [SortClause]) {
        if case .savedView(let id) = pane,
           let index = savedViews.firstIndex(where: { $0.id == id }) {
            savedViews[index].sorts = clauses
        } else {
            sortClauses = clauses
        }
        recomputeVisible()
    }

    func setFilters(_ clauses: [FilterClause], match: FilterMatch = .all) {
        if case .savedView(let id) = pane,
           let index = savedViews.firstIndex(where: { $0.id == id }) {
            savedViews[index].clauses = clauses
            savedViews[index].match = match
        } else {
            filterClauses = clauses
            filterMatch = match
        }
        recomputeVisible()
    }

    // MARK: saved views (QUA-127)

    /// Snapshot the current pane's filtering as a named view and switch to it.
    /// In a type/theme bucket the bucket itself becomes a leading clause —
    /// the view's universe is ALL types, so without it「paper 桶里 rating≥4」
    /// would silently widen to every type. Skipped under `.any` match, where
    /// an injected clause would OR instead of constrain. Half-typed clauses
    /// are dropped at save time.
    @discardableResult
    func createSavedView(named name: String) -> SavedView {
        var clauses = activeFilterClauses.filter(clauseReady)
        if activeFilterMatch == .all {
            switch pane {
            case .type(let t) where !clauses.contains(where: { $0.field == .type }):
                clauses.insert(FilterClause(field: .type, op: .is_, value: t.rawValue), at: 0)
            case .theme(let name) where !clauses.contains(where: { $0.field == .theme }):
                clauses.insert(FilterClause(field: .theme, op: .is_, value: name), at: 0)
            default:
                break
            }
        }
        let view = SavedView(name: name, clauses: clauses,
                             match: activeFilterMatch, sorts: activeSortClauses)
        savedViews.append(view)
        select(pane: .savedView(view.id))
        return view
    }

    func renameSavedView(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = savedViews.firstIndex(where: { $0.id == id }) else { return }
        savedViews[index].name = trimmed
    }

    func deleteSavedView(_ id: UUID) {
        savedViews.removeAll { $0.id == id }
        if case .savedView(let current) = browsePane, current == id {
            select(pane: .type(visibleTypeOrder.first ?? .paper))
        }
    }

    /// Reorder a saved view to a sidebar drop slot — `index` is the drop
    /// indicator's position among the current rows, counted BEFORE the dragged
    /// view is removed (same slot semantics as the type-bucket reorder). QUA-210.
    @discardableResult
    func moveSavedView(_ id: UUID, to index: Int) -> Bool {
        guard let from = savedViews.firstIndex(where: { $0.id == id }) else { return false }
        var views = savedViews
        let view = views.remove(at: from)
        let dropAt = min(max(from < index ? index - 1 : index, 0), views.count)
        views.insert(view, at: dropAt)
        savedViews = views
        return true
    }

    /// SwiftUI's TextField with a custom Binding can echo the current value
    /// back through its setter whenever the parent view re-evaluates (the
    /// `SearchField` here re-renders on any @Observable AppModel mutation
    /// because it holds `@Bindable model`). Without this guard, every click
    /// on a card → openPath change → SearchField body re-eval → TextField
    /// setter calls `setSearchText('go')` with the SAME 'go' → runSearch
    /// pumps a redundant network search → searchMatches clears+repopulates
    /// → two full reloadData passes (visible "list rebuilds and settles").
    func setSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        if !isBrowsing, workspace?.activeTab.pinned == false,
           let location = workspace?.activeTab.location {
            mutateWorkspace {
                $0.replaceActiveLocation(with: NavLocation(
                    pane: location.pane, openPath: location.openPath, searchText: text))
            }
        }
        runSearch()
    }

    /// Debounced server search scoped to the current type pane (nil type → all).
    private func runSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = []; clearSearchMatches(); recomputeVisible(); return }
        let type: EntryType? = {
            if !isPinnedListContext, case .type(let t) = pane { return t }
            return nil
        }()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let hits = try await self?.client.search(SearchQuery(q: q, type: type)) ?? []
                if Task.isCancelled { return }
                self?.searchHits = hits
                self?.recomputeVisible()
                guard let self else { return }
                self.catalog.computeSearchMatches(
                    query: q, paths: self.visibleEntries.map(\.path), client: self.client,
                    currentSearchText: { [weak self] in self?.searchText ?? "" })
                print("[marple] search '\(q)' -> \(hits.count) hits")
            } catch {
                self?.status = String(localized: "搜索失败：\(error)")
                print("[marple] search FAILED '\(q)': \(error)")
            }
        }
    }

    private func clearSearchMatches() {
        catalog.clearSearchMatches()
    }

    /// Toggle a result row's "再显示 N 个匹配项" expander.
    func toggleMatchExpanded(_ path: String) {
        catalog.toggleMatchExpanded(path)
    }

    /// Open `path` from a clicked search matched-line: opens browser-style (in-place
    /// while reading, new tab while browsing) and tells the reader to highlight the
    /// query + scroll to the clicked line.
    func openMatchedLine(path: String, query: String, ordinal: Int, anchor: String) async {
        await activateVisibleEntry(path)
        openSearchQuery = query
        matchJump = MatchJump(query: query, anchor: anchor, ordinal: ordinal)
    }

    private func clearReaderHighlight() {
        openSearchQuery = nil
        matchJump = nil
        // QUA-151: drop any outline scroll target left over from the previous doc,
        // so a stale block index can't hijack the next document's scroll position.
        scrollTarget = nil
    }

    /// Open `path`. Context-dependent (browser-style): from the browse list (browsing)
    /// it spawns a NEW document tab; while reading it switches the current tab IN-PLACE
    /// (pushes history, so ◀ returns) instead of piling up tabs. Explicit "open in new
    /// tab" always spawns one.
    func open(_ path: String) async {
        clearReaderHighlight()
        if isBrowsing || workspace == nil {
            await openNewTab(path)
        } else {
            let location = sourceLocation(for: path)
            mutateWorkspace { $0.navigateActive(to: location) }
            isBrowsing = false
            await loadDoc(path)
        }
    }

    private func openNewTab(_ path: String) async {
        let restoreSourceContext = isPinnedListContext
        let loc = sourceLocation(for: path)
        if workspace == nil {
            workspace = Workspace(initial: loc)
        } else {
            mutateWorkspace { $0.newTab(loc) }
        }
        isBrowsing = false
        if restoreSourceContext { resetSearch(to: loc.searchText ?? "") }
        await loadDoc(path)
    }

    /// Fetch + render the doc at `path` into the open-doc caches. `nil` clears them.
    /// Always loads (no `loadedDocPath` guard) so it doubles as the FSEvents refresh.
    private func loadDoc(_ path: String?) async {
        writeError = nil
        if path != loadedDocPath {
            await flushAllInspectorNoteSaves()
            let nextTargetPath = entries.first(where: { $0.path == path })
                .map { annotationTarget(for: $0, in: entries).path }
            if inspectorSelectedNoteEntry?.annotates != nextTargetPath { clearInspectorNoteSelection() }
        }
        guard let path else {
            openBlocks = []; openBody = ""; loadedDocPath = nil
            recomputeOpenDerived()
            return
        }
        do {
            let raw = try await client.entryText(path: path)
            let body = Frontmatter.split(raw).body
            // Watcher refreshes land here for ANY vault change (e.g. inline-note
            // autosaves, issue #87). When the doc text didn't change, skip the
            // re-parse/republish; still recompute derived state — the index the
            // relations panel reads may have moved.
            if path == loadedDocPath, body == openBody {
                recomputeOpenDerived()
                return
            }
            openBody = body
            openBlocks = MarkdownModel.blocks(from: openBody)
            loadedDocPath = path
            recomputeOpenDerived()
            print("[marple] open \(path) -> \(openBlocks.count) blocks (\(raw.count) chars)")
        } catch {
            openBlocks = [.paragraph([.text("load failed: \(error)")])]
            openBody = ""; loadedDocPath = path
            recomputeOpenDerived()
            print("[marple] open FAILED \(path): \(error)")
        }
    }

    /// Bring the visible list + open doc in line with the active tab's location.
    /// Used after history nav, tab switch, new/close tab. Reloads the doc only when
    /// it differs from what's already loaded.
    private func syncToActiveLocation() async {
        resetSearch(to: isPinnedListContext ? "" : workspace?.activeTab.location.searchText ?? "")
        clearReaderHighlight()
        if openPath != loadedDocPath { await loadDoc(openPath) }
    }

    private func resetSearch(to text: String) {
        searchTask?.cancel()
        searchText = text
        searchHits = []
        clearSearchMatches()
        recomputeVisible()
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { runSearch() }
    }

    private func sourceLocation(for path: String) -> NavLocation {
        if !isBrowsing, let source = workspace?.activeTab.location {
            return NavLocation(pane: source.pane, openPath: path, searchText: source.searchText)
        }
        return NavLocation(pane: browsePane, openPath: path, searchText: searchText)
    }

    func reloadOpen() async {
        if let p = openPath { print("[marple] watcher reload \(p)"); await loadDoc(p) }
    }

    func follow(_ target: String) async {
        guard let hit = NameResolver.resolveWikilink(target, in: entries) else {
            status = String(localized: "未解析链接：[[\(target)]]")
            print("[marple] follow [[\(target)]] -> UNRESOLVED")
            return
        }
        print("[marple] follow [[\(target)]] -> \(hit.path)")
        clearReaderHighlight()
        // Wikilink follow stays WITHIN the current tab (per-tab history); if we're
        // browsing (no active tab), open it as a new tab instead.
        if !isBrowsing, workspace != nil {
            let location = sourceLocation(for: hit.path)
            mutateWorkspace { $0.navigateActive(to: location) }
            await loadDoc(hit.path)
        } else {
            await open(hit.path)
        }
    }

    // MARK: history + tabs

    func goBack() async {
        guard canGoBack else { return }
        mutateWorkspace { $0.backActive() }
        print("[marple] back -> \(openPath ?? "browse")")
        await syncToActiveLocation()
    }

    func goForward() async {
        guard canGoForward else { return }
        mutateWorkspace { $0.forwardActive() }
        print("[marple] forward -> \(openPath ?? "browse")")
        await syncToActiveLocation()
    }

    /// "New tab" in a documents-only tab model = a fresh note (a new page).
    func newTab() async { await newIdeaNote() }

    /// Always open `path` in a new tab (right-click / ⌘-click).
    func openInNewTab(_ path: String) async { await openNewTab(path) }

    /// Open `path` as a new tab in the active space and return the new tab's id, so
    /// a drop handler can then position it (root index / group). QUA-114.
    func openEntryTab(_ path: String) async -> NavTab.ID? {
        await openNewTab(path)
        return workspace?.activeID
    }

    // MARK: - Command palette (⌘T)

    /// Run a cross-type palette search. 快速 = in-memory field-weighted ranker;
    /// 平衡 = native FTS full-text (server order preserved via a descending synthetic
    /// score); 深度 = semantic vectors, returned empty until the vector index exists.
    func commandSearch(_ query: String, mode: SearchMode) async -> [PaletteResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        switch mode {
        case .fast:
            // Rank ~15k docs OFF the main actor so typing never hitches. Trigram
            // prefilter inside `searchDocuments` typically narrows to <300 docs
            // before scoring (QUA-96).
            let index = searchIndex
            let ranked = await Task.detached(priority: .userInitiated) {
                searchDocuments(index, q)
            }.value
            return ranked.map { PaletteResult(entry: $0.entry, score: $0.score, source: nil) }
        case .balanced:
            do {
                let hits = try await client.search(SearchQuery(q: q, type: nil, limit: 300))
                return hits.enumerated().map {
                    PaletteResult(entry: $0.element.entry,
                                  score: Double(hits.count - $0.offset),
                                  source: $0.element.source)
                }
            } catch {
                print("[marple] palette balanced search FAILED '\(q)': \(error)")
                return []
            }
        case .deep:
            guard let semantic else { return [] }
            do {
                let hits = try await semantic.search(q, topK: 80)
                let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                return hits.compactMap { hit in
                    byPath[hit.path].map { PaletteResult(entry: $0, score: hit.score, source: "vec") }
                }
            } catch {
                print("[marple] palette deep search FAILED '\(q)': \(error)")
                return []
            }
        }
    }

    /// Pick a result: open in-place (browser-style) or in a new tab when ⌘ was held.
    /// (The panel closes itself via its `onClose`.)
    func openFromPalette(_ path: String, newTab: Bool) async {
        if newTab { await openInNewTab(path) } else { await open(path) }
    }

    /// "查看全部 N 条 →": jump to that type's browse list, seed its search box.
    func paletteViewAll(type: EntryType, query: String) {
        select(pane: .type(type))
        setSearchText(query)
    }

    /// Active-Space document paths currently open in a tab, minus the one already
    /// on screen. The palette surfaces matches among these as "switch to tab"
    /// (Arc-style) so picking one jumps to the existing tab instead of opening a
    /// duplicate. Scoped to the active Space — each Space is its own workspace.
    var openTabPaths: Set<String> {
        var paths = Set(tabs.compactMap { $0.location.openPath })
        if let current = openPath { paths.remove(current) }
        return paths
    }

    /// Switch to the active-Space tab currently showing `path` (first match).
    func switchToOpenTab(path: String) async {
        guard let id = tabs.first(where: { $0.location.openPath == path })?.id else { return }
        await selectTab(id)
    }

    func selectTab(_ id: NavTab.ID) async {
        mutateWorkspace { $0.select(id) }
        isBrowsing = false
        await syncToActiveLocation()
    }

    /// The pinned middle list switches existing tabs; object lists keep their
    /// browser-style open behavior.
    func activateVisibleEntry(_ path: String) async {
        guard isPinnedListContext,
              let id = tabs.first(where: { $0.pinned && $0.location.openPath == path })?.id
        else {
            await open(path)
            return
        }
        guard id != activeTabID else { return }
        mutateWorkspace { $0.select(id) }
        isBrowsing = false
        clearReaderHighlight()
        if openPath != loadedDocPath { await loadDoc(openPath) }
    }

    func selectTab(index: Int) async {
        mutateWorkspace { $0.selectIndex(index) }
        isBrowsing = false
        await syncToActiveLocation()
    }

    func selectNextTab() async {
        let previousActiveID = activeTabID
        mutateWorkspace { $0.selectRelative(1) }
        isBrowsing = false
        if activeTabID != previousActiveID { await syncToActiveLocation() }
    }

    func selectPrevTab() async {
        let previousActiveID = activeTabID
        mutateWorkspace { $0.selectRelative(-1) }
        isBrowsing = false
        if activeTabID != previousActiveID { await syncToActiveLocation() }
    }

    /// Close a document tab. Closing the last one drops back to the browse list.
    func closeTab(_ id: NavTab.ID) async {
        let previousActiveID = activeTabID
        guard var ws = workspace else { return }
        ws.closeTab(id)
        if ws.tabs.isEmpty {
            workspace = nil
            isBrowsing = true
        } else {
            workspace = ws
        }
        if activeTabID != previousActiveID { await syncToActiveLocation() }
    }

    /// Close the active tab (⌘W). Skips a pinned tab.
    func closeActiveTab() async {
        guard !isBrowsing, let ws = workspace, !ws.activeTab.pinned, let id = activeTabID else { return }
        await closeTab(id)
    }

    /// Close every tab except `keep` and any pinned tabs.
    func closeOtherTabs(_ keep: NavTab.ID) async {
        let previousActiveID = activeTabID
        guard var ws = workspace else { return }
        let toClose = ws.tabs.filter { $0.id != keep && !$0.pinned }.map(\.id)
        guard !toClose.isEmpty else { return }
        for id in toClose { ws.closeTab(id) }
        ws.select(keep)
        workspace = ws
        if activeTabID != previousActiveID { await syncToActiveLocation() }
    }

    /// Close every tab in `ids` skipping pinned. Empties drop back to browse mode
    /// the same way the single-tab close does.
    func closeTabs(_ ids: Set<NavTab.ID>) async {
        let previousActiveID = activeTabID
        guard var ws = workspace else { return }
        ws.closeTabs(ids)
        if ws.tabs.isEmpty {
            workspace = nil
            isBrowsing = true
        } else {
            workspace = ws
        }
        if activeTabID != previousActiveID { await syncToActiveLocation() }
    }

    /// Form one new group at the earliest selected tab's position, containing all
    /// `ids` in DFS order. No-op if fewer than two valid tabs.
    func groupTabs(_ ids: [NavTab.ID]) { mutateWorkspace { $0.groupTabs(ids) } }

    /// Bulk move `ids` into `groupID` at `childIndex` (or append) preserving order.
    func moveTabs(_ ids: [NavTab.ID], toGroup groupID: TabGroup.ID, at childIndex: Int? = nil) {
        mutateWorkspace { $0.moveTabs(ids, toGroup: groupID, at: childIndex) }
    }

    func moveTabsToRoot(_ ids: [NavTab.ID], at index: Int? = nil) {
        mutateWorkspace { $0.moveTabsToRoot(ids, at: index) }
    }

    func moveGroupsToRoot(_ ids: [TabGroup.ID], at index: Int? = nil) {
        mutateWorkspace { $0.moveGroupsToRoot(ids, at: index) }
    }

    /// Interleaved bulk move (tabs + groups together). Used by multi-drag to
    /// preserve the source/visual order of a mixed selection.
    func moveItems(_ items: [WorkspaceItem], toGroup groupID: TabGroup.ID, at childIndex: Int? = nil) {
        mutateWorkspace { $0.moveItems(items, toGroup: groupID, at: childIndex) }
    }

    func moveItemsToRoot(_ items: [WorkspaceItem], at index: Int? = nil) {
        mutateWorkspace { $0.moveItemsToRoot(items, at: index) }
    }

    /// "上级胜出": filter a payload set so descendants of selected ancestors fall
    /// out (their ancestors will move them implicitly).
    func payloadAncestorFilter(tabIDs: [NavTab.ID],
                               groupIDs: [TabGroup.ID]) -> (tabs: [NavTab.ID], groups: [TabGroup.ID]) {
        workspace?.payloadAncestorFilter(tabIDs: tabIDs, groupIDs: groupIDs) ?? (tabIDs, groupIDs)
    }

    func togglePin(_ id: NavTab.ID) {
        let wasActive = activeTabID == id
        mutateWorkspace { $0.togglePin(id) }
        guard wasActive else { return }
        resetSearch(to: isPinnedListContext ? "" : workspace?.activeTab.location.searchText ?? "")
    }

    func renameTab(_ id: NavTab.ID, to title: String?) {
        mutateWorkspace { $0.renameTab(id, to: title) }
    }

    func renameTabGroup(_ id: TabGroup.ID, to name: String) {
        mutateWorkspace { $0.renameGroup(id, to: name) }
    }

    func setTabOrder(_ ids: [NavTab.ID]) { mutateWorkspace { $0.reorder(ids) } }

    func tabGroup(containing tabID: NavTab.ID) -> TabGroup? {
        workspace?.group(containing: tabID)
    }

    func tabs(in groupID: TabGroup.ID) -> [NavTab] {
        workspace?.tabs(in: groupID) ?? []
    }

    func groupTab(_ sourceID: NavTab.ID, onto targetID: NavTab.ID) {
        mutateWorkspace { $0.groupTab(sourceID, onto: targetID) }
    }

    func moveTab(_ tabID: NavTab.ID, toGroup groupID: TabGroup.ID, at childIndex: Int? = nil) {
        mutateWorkspace { $0.moveTab(tabID, toGroup: groupID, at: childIndex) }
    }

    func moveTabToRoot(_ tabID: NavTab.ID, beforeTab targetID: NavTab.ID?) {
        mutateWorkspace { $0.moveTabToRoot(tabID, beforeTab: targetID) }
    }

    func moveGroup(_ groupID: TabGroup.ID, beforeTab targetID: NavTab.ID?) {
        mutateWorkspace { $0.moveGroup(groupID, beforeTab: targetID) }
    }

    func moveGroup(_ sourceGroupID: TabGroup.ID, beforeGroup targetGroupID: TabGroup.ID) {
        mutateWorkspace { $0.moveGroup(sourceGroupID, beforeGroup: targetGroupID) }
    }

    func moveGroup(_ groupID: TabGroup.ID, intoGroup parentID: TabGroup.ID, at childIndex: Int? = nil) {
        mutateWorkspace { $0.moveGroup(groupID, intoGroup: parentID, at: childIndex) }
    }

    func moveGroupToRoot(_ groupID: TabGroup.ID, at index: Int? = nil) {
        mutateWorkspace { $0.moveGroupToRoot(groupID, at: index) }
    }

    /// False if nesting `source` into `target` would create a cycle (self or descendant).
    func canNestGroup(_ source: TabGroup.ID, into target: TabGroup.ID) -> Bool {
        guard source != target, let ws = workspace else { return false }
        return !ws.group(target, isInsideSubtreeOf: source)
    }

    func groupContainsTab(_ groupID: TabGroup.ID, _ tabID: NavTab.ID) -> Bool {
        workspace?.group(groupID, containsTab: tabID) ?? false
    }

    func outermostCollapsedTabGroup(of tabID: NavTab.ID) -> TabGroup.ID? {
        workspace?.outermostCollapsedAncestor(of: tabID)
    }

    func toggleTabGroup(_ groupID: TabGroup.ID) {
        mutateWorkspace { $0.toggleGroupCollapsed(groupID) }
    }

    func setTabGroup(_ groupID: TabGroup.ID, collapsed: Bool) {
        mutateWorkspace { $0.setGroupCollapsed(groupID, collapsed: collapsed) }
    }

    // MARK: tab labels

    /// Title resolution: user-renamed → live entry title → last-session cached
    /// title (kept in `NavTab.cachedTitle`, populated from PersistedState at
    /// restore) → path basename. The cachedTitle fallback is what keeps the
    /// sidebar tab list from showing raw `00-overview.md` filenames during
    /// the bootstrap window before `entries` has loaded (QUA-105).
    func tabTitle(_ tab: NavTab) -> String {
        if let customTitle = tab.customTitle { return customTitle }
        let loc = tab.location
        if let p = loc.openPath {
            if let live = entries.first(where: { $0.path == p })?.title { return live }
            if let cached = tab.cachedTitle, !cached.isEmpty { return cached }
            return (p as NSString).lastPathComponent
        }
        switch loc.pane {
        case .type(let t): return AppPresentation.entryTypeLabel(t)
        case .theme(let name): return "#\(name)"
        case .themesIndex: return String(localized: "标签")
        case .trash: return String(localized: "回收站")
        case .savedView(let id): return savedView(id)?.name ?? String(localized: "视图")
        }
    }

    func tabIsDoc(_ tab: NavTab) -> Bool { tab.location.openPath != nil }

    // MARK: share manifest

    /// Markdown manifest for a single tab (one bullet, no header). Nil if the tab is gone.
    func shareManifest(forTab id: NavTab.ID) -> String? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        return renderTabShareManifest([shareNode(for: tab)])
    }

    /// Markdown manifest for a group: an H1 of the group name plus a nested bullet list
    /// mirroring the folder structure. Nil if the group is gone.
    func shareManifest(forGroup id: TabGroup.ID) -> String? {
        guard let group = tabGroups.first(where: { $0.id == id }) else { return nil }
        return renderTabShareManifest([shareNode(for: group)])
    }

    private func shareNode(for group: TabGroup) -> TabShareNode {
        .group(name: group.name, children: group.children.compactMap(shareChild))
    }

    private func shareChild(_ node: TabNode) -> TabShareNode? {
        switch node {
        case .tab(let id):
            guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
            return shareNode(for: tab)
        case .group(let g):
            return shareNode(for: g)
        }
    }

    private func shareNode(for tab: NavTab) -> TabShareNode {
        .tab(name: tab.customTitle, title: originalTabTitle(tab), absolutePath: absolutePath(of: tab))
    }

    /// `tabTitle` minus the user-rename override, so the manifest keeps the document's
    /// own title even when the tab was renamed.
    private func originalTabTitle(_ tab: NavTab) -> String {
        let loc = tab.location
        if let p = loc.openPath {
            if let live = entries.first(where: { $0.path == p })?.title { return live }
            if let cached = tab.cachedTitle, !cached.isEmpty { return cached }
            return (p as NSString).lastPathComponent
        }
        switch loc.pane {
        case .type(let t): return AppPresentation.entryTypeLabel(t)
        case .theme(let name): return "#\(name)"
        case .themesIndex: return String(localized: "标签")
        case .trash: return String(localized: "回收站")
        case .savedView(let id): return savedView(id)?.name ?? String(localized: "视图")
        }
    }

    private func absolutePath(of tab: NavTab) -> String? {
        guard let p = tab.location.openPath else { return nil }
        return URL(fileURLWithPath: workspaceRoot).appendingPathComponent(p).path
    }

    func openExternally() async {
        guard let p = openPath else { return }
        await openExternally(path: p)
    }

    private func openExternally(path: String) async {
        let app = UserDefaults.standard.string(forKey: SettingsKeys.externalEditor) ?? ""
        do {
            try await client.openInEditor(path: path, app: app)
            print("[marple] openInEditor \(path) app='\(app)'")
        } catch {
            status = String(localized: "无法在外部编辑器中打开：\(error)")
            print("[marple] openInEditor FAILED \(path): \(error)")
        }
    }

    // MARK: inspector note editing

    func ensureInspectorNoteLoaded(_ note: Entry) async {
        guard canEditInspectorNote(note), inspectorNoteDrafts[note.path] == nil else { return }
        inspectorNoteStatuses[note.path] = .loading
        do {
            let raw = try await client.entryText(path: note.path)
            let body = Frontmatter.split(raw).body
            inspectorNoteDrafts[note.path] = body
            inspectorNoteOriginals[note.path] = body
            inspectorNoteStatuses[note.path] = .idle
            syncLegacyInspectorNoteState(path: note.path)
        } catch {
            inspectorNoteStatuses[note.path] = .failed("\(error)")
            writeError = "\(error)"
            print("[marple] load note FAILED \(note.path): \(error)")
        }
    }

    func inspectorNoteDraft(for path: String) -> String { inspectorNoteDrafts[path] ?? "" }
    func inspectorNoteStatus(for path: String) -> InspectorNoteStatus { inspectorNoteStatuses[path] ?? .idle }

    func setInspectorNoteFocused(_ note: Entry, focused: Bool) {
        guard canEditInspectorNote(note) else { return }
        if focused {
            inspectorFocusedNotePath = note.path
            inspectorSelectedNotePath = note.path
            inspectorSelectedNoteEntry = note
            syncLegacyInspectorNoteState(path: note.path)
        } else if inspectorFocusedNotePath == note.path {
            inspectorFocusedNotePath = nil
        }
    }

    func setInspectorNoteDraft(_ text: String, for note: Entry) {
        guard canEditInspectorNote(note) else { return }
        let path = note.path
        if inspectorNoteDrafts[path] == text { return }
        inspectorNoteDrafts[path] = text
        inspectorSelectedNotePath = path
        inspectorSelectedNoteEntry = note
        let original = inspectorNoteOriginals[path] ?? ""
        if text == original {
            inspectorNoteStatuses[path] = .saved
            inspectorNoteSaveTasks[path]?.cancel(); inspectorNoteSaveTasks[path] = nil
        } else {
            inspectorNoteStatuses[path] = .dirty
            scheduleInspectorNoteSave(path: path)
        }
        syncLegacyInspectorNoteState(path: path)
    }

    func saveInspectorNoteDraft(_ text: String, for note: Entry) {
        guard canEditInspectorNote(note) else { return }
        let path = note.path
        inspectorNoteDrafts[path] = text
        inspectorSelectedNotePath = path
        inspectorSelectedNoteEntry = note
        let original = inspectorNoteOriginals[path] ?? ""
        if text == original {
            inspectorNoteStatuses[path] = .saved
            syncLegacyInspectorNoteState(path: path)
            return
        }
        inspectorNoteStatuses[path] = .dirty
        syncLegacyInspectorNoteState(path: path)
        Task { await flushInspectorNoteSave(path: path) }
    }

    func flushInspectorNoteSave() async {
        guard let path = inspectorSelectedNotePath else { return }
        await flushInspectorNoteSave(path: path)
    }

    /// Unsaved staged edits — the quit hook only delays termination when true.
    var hasDirtyInspectorNotes: Bool {
        inspectorNoteDrafts.contains { inspectorNoteOriginals[$0.key] != $0.value }
    }

    func flushAllInspectorNoteSaves() async {
        let paths = Array(inspectorNoteDrafts.keys)
        for path in paths { await flushInspectorNoteSave(path: path) }
    }

    private func flushInspectorNoteSave(path: String) async {
        inspectorNoteSaveTasks[path]?.cancel(); inspectorNoteSaveTasks[path] = nil
        guard canEditInspectorNotePath(path), let text = inspectorNoteDrafts[path] else { return }
        let original = inspectorNoteOriginals[path] ?? ""
        guard text != original else {
            if inspectorNoteStatuses[path] != .loading { inspectorNoteStatuses[path] = .saved }
            syncLegacyInspectorNoteState(path: path)
            return
        }
        inspectorNoteStatuses[path] = .saving
        syncLegacyInspectorNoteState(path: path)
        writeError = nil
        do {
            let raw = try await client.entryText(path: path)
            let patched = MarkdownBody.replace(in: raw, with: text)
            try await client.writeFile(path: path, text: patched)
            inspectorNoteOriginals[path] = text
            inspectorNoteStatuses[path] = (inspectorNoteDrafts[path] == text) ? .saved : .dirty
            syncLegacyInspectorNoteState(path: path)
            let preview = Self.notePreview(from: text)
            catalog.mutateEntries { entries in
                if let i = entries.firstIndex(where: { $0.path == path }) {
                    entries[i] = entries[i].with(preview: preview)
                }
            }
            // No eager rebuildIndexDerived/recomputeVisible/recomputeOpenDerived
            // here: the FSEvents pass triggered by this very write redoes all of
            // them moments later, and running the full index-wide recomputes on
            // every autosave is what made typing stutter (issue #87).
            print("[marple] saved inspector note \(path)")
        } catch {
            inspectorNoteStatuses[path] = .failed("\(error)")
            syncLegacyInspectorNoteState(path: path)
            writeError = "\(error)"
            print("[marple] save inspector note FAILED \(path): \(error)")
        }
    }

    func createInlineAnnotationForOpenDoc() async {
        guard let openEntry else { return }
        guard canCreateInlineAnnotationForOpenDoc else { return }
        let target = annotationTarget(for: openEntry, in: entries)
        await flushAllInspectorNoteSaves()
        let draft = NoteBuilder.annotation(target: target)
        let entry = annotationEntry(from: draft, target: target)
        let initialText = MarkdownBody.replace(in: draft.text, with: "")
        writeError = nil
        do {
            try await client.createNote(path: draft.path, text: initialText)
            catalog.mutateEntries { $0.append(entry) }
            rebuildIndexDerived(); recomputeVisible(); recomputeOpenDerived()
            inspectorSelectedNotePath = entry.path
            inspectorSelectedNoteEntry = entry
            inspectorFocusedNotePath = entry.path
            let body = Frontmatter.split(initialText).body
            inspectorNoteDrafts[entry.path] = body
            inspectorNoteOriginals[entry.path] = body
            inspectorNoteStatuses[entry.path] = .saved
            syncLegacyInspectorNoteState(path: entry.path)
            flash(String(localized: "已新建笔记"))
            print("[marple] created inline note \(draft.path)")
        } catch {
            writeError = "\(error)"
            inspectorNoteStatus = .failed("\(error)")
            print("[marple] create inline note FAILED \(draft.path): \(error)")
        }
    }

    func openInspectorNoteExternally() async {
        guard let path = inspectorSelectedNotePath else { return }
        await flushInspectorNoteSave(path: path)
        await openExternally(path: path)
    }

    private func clearInspectorNoteSelection() {
        inspectorNoteSaveTask?.cancel(); inspectorNoteSaveTask = nil
        inspectorNoteSaveTasks.values.forEach { $0.cancel() }
        inspectorNoteSaveTasks = [:]
        inspectorSelectedNotePath = nil
        inspectorSelectedNoteEntry = nil
        inspectorFocusedNotePath = nil
        inspectorNoteDraft = ""
        inspectorNoteOriginal = ""
        inspectorNoteStatus = .idle
        inspectorNoteDrafts = [:]
        inspectorNoteOriginals = [:]
        inspectorNoteStatuses = [:]
        inspectorNoteHeights = [:]
    }

    private func scheduleInspectorNoteSave(path: String) {
        inspectorNoteSaveTasks[path]?.cancel()
        inspectorNoteSaveTasks[path] = Task { [weak self] in
            // Safety net only: the primary flush points are blur, doc switch,
            // and quit. Writing while the user types kicks off a full vault
            // reindex mid-IME-composition (issue #87), so keep this long.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushInspectorNoteSave(path: path)
        }
    }

    private func syncLegacyInspectorNoteState(path: String) {
        guard inspectorSelectedNotePath == path else { return }
        inspectorNoteDraft = inspectorNoteDrafts[path] ?? ""
        inspectorNoteOriginal = inspectorNoteOriginals[path] ?? ""
        inspectorNoteStatus = inspectorNoteStatuses[path] ?? .idle
    }

    private func inspectorNoteComesBefore(_ a: Entry, _ b: Entry) -> Bool {
        let ac = a.created ?? ""
        let bc = b.created ?? ""
        if ac != bc { return ac < bc }
        // No mtime tiebreak: `created` is date-only, so same-day notes always
        // tied — and every autosave bumps mtime, making the card being edited
        // jump to the end of the list after each reindex (issue #87).
        return a.path < b.path
    }

    private func canEditInspectorNote(_ entry: Entry) -> Bool {
        entry.type == .note && canEditInspectorNotePath(entry.path)
    }

    private func canEditInspectorNotePath(_ path: String) -> Bool {
        path.hasPrefix("vault/notes/")
    }

    private static func notePreview(from text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    var openCitationEntry: Entry? {
        guard let e = openEntry else { return nil }
        return citationEntry(for: e, in: entries)
    }

    private var openPDFSlug: String? {
        guard let e = openEntry, let slug = pdfEntry(for: e, in: entries)?.pdfSlug, !slug.isEmpty else { return nil }
        return slug
    }

    private var openTranslationSlug: String? {
        guard let e = openEntry else { return nil }
        return sourceSlugCandidates(for: e, in: entries).first { client.hasTranslation(slug: $0) }
    }

    func openPDF() async {
        guard let slug = openPDFSlug else { return }
        do {
            try await client.openPDF(slug: slug)
            print("[marple] openPDF \(slug)")
        } catch {
            status = String(localized: "打开 PDF 失败：\(error)")
            print("[marple] openPDF FAILED \(slug): \(error)")
        }
    }

    func openTranslation() async {
        guard let slug = openTranslationSlug else { return }
        do {
            try await client.openTranslation(slug: slug)
            print("[marple] openTranslation \(slug)")
        } catch {
            status = String(localized: "打开译本失败：\(error)")
            print("[marple] openTranslation FAILED \(slug): \(error)")
        }
    }

    func runReaderAIAction(_ action: ReaderAIAction) async {
        guard let path = openPath, let entry = openEntry else {
            flash(String(localized: "请先打开一篇文档。"), symbol: "exclamationmark.triangle.fill")
            return
        }

        let defaults = UserDefaults.standard
        let config = ReaderAIDispatchConfig(
            workspaceID: defaults.string(forKey: SettingsKeys.supersetWorkspaceID) ?? "",
            agent: defaults.string(forKey: SettingsKeys.readerAIAgent) ?? "claude",
            cliPath: defaults.string(forKey: SettingsKeys.supersetCLIPath) ?? "superset",
            commandTemplate: AIDispatchTarget.resolveTemplate(
                targetRawValue: defaults.string(forKey: SettingsKeys.aiDispatchTarget),
                storedTemplate: defaults.string(forKey: SettingsKeys.aiDispatchTemplate)
            ),
            reanalyzePrompt: defaults.string(forKey: SettingsKeys.readerAIReanalyzePrompt),
            formatPrompt: defaults.string(forKey: SettingsKeys.readerAIFormatPrompt),
            translatePrompt: defaults.string(forKey: SettingsKeys.readerAITranslatePrompt),
            discussPrompt: defaults.string(forKey: SettingsKeys.readerAIDiscussPrompt)
        )

        do {
            let raw = try await client.entryText(path: path)
            let context = try ReaderAIDispatchContext(
                workspaceRoot: workspaceRoot,
                targetPath: path,
                entry: entry,
                documentText: raw,
                related: readerAIRelatedContext(for: entry, rawDocumentText: raw)
            )
            try await readerAIRunner.dispatch(action: action, config: config, context: context)
            flash(String(localized: "已分发：\(AppPresentation.readerAIActionLabel(action))"), symbol: "sparkles")
            print("[marple] dispatch \(action.rawValue) \(path)")
        } catch let error as ReaderAIDispatchError {
            flash(AppPresentation.readerAIDispatchErrorLabel(error), symbol: "exclamationmark.triangle.fill")
            print("[marple] dispatch \(action.rawValue) FAILED \(path): \(error)")
        } catch {
            flash(String(localized: "AI 分发失败，请查看日志。"), symbol: "exclamationmark.triangle.fill")
            print("[marple] dispatch \(action.rawValue) FAILED \(path): \(error)")
        }
    }

    private func readerAIRelatedContext(for entry: Entry, rawDocumentText: String) -> ReaderAIRelatedContext {
        let annotations = (openRelations?.annotations.prefix(12) ?? [])
            .map { ReaderAIRelatedEntry(entry: $0, reason: "annotation") }

        var bookEntries: [(entry: Entry, reason: String)] = []
        if let overview = openBook?.overview, overview.path != entry.path {
            bookEntries.append((overview, "book overview"))
        }
        if let chapters = openBook?.chapters {
            bookEntries.append(contentsOf: chapters
                .filter { $0.path != entry.path }
                .prefix(20)
                .map { (entry: $0, reason: "book chapter") })
        }

        var relatedEntries: [(entry: Entry, reason: String)] = []
        if let relations = openRelations {
            relatedEntries.append(contentsOf: relations.works.map { (entry: $0, reason: "author work") })
            relatedEntries.append(contentsOf: relations.siblings.map { (entry: $0, reason: "same author") })
            relatedEntries.append(contentsOf: relations.similar.map { (entry: $0, reason: "shared themes") })
        }

        return ReaderAIRelatedContext(
            annotations: annotations,
            bookEntries: uniqueReaderAIEntries(bookEntries).map { ReaderAIRelatedEntry(entry: $0.entry, reason: $0.reason) },
            relatedWorks: Array(uniqueReaderAIEntries(relatedEntries).prefix(12))
                .map { ReaderAIRelatedEntry(entry: $0.entry, reason: $0.reason) },
            wikilinks: readerAIWikilinks(from: rawDocumentText),
            sourcePaths: readerAISourcePaths(for: entry)
        )
    }

    private func uniqueReaderAIEntries(_ entries: [(entry: Entry, reason: String)]) -> [(entry: Entry, reason: String)] {
        var seen = Set<String>()
        var unique: [(entry: Entry, reason: String)] = []
        for item in entries where !seen.contains(item.entry.path) {
            seen.insert(item.entry.path)
            unique.append(item)
        }
        return unique
    }

    private func readerAIWikilinks(from rawDocumentText: String) -> [ReaderAIWikiTarget] {
        let body = Frontmatter.split(rawDocumentText).body
        let refs = Wikilink.protect(body).refs.values.sorted {
            if $0.target == $1.target { return $0.label < $1.label }
            return $0.target < $1.target
        }
        var seen = Set<String>()
        var targets: [ReaderAIWikiTarget] = []
        for ref in refs where !seen.contains(ref.target) {
            seen.insert(ref.target)
            guard let resolved = NameResolver.resolveWikilink(ref.target, in: entries) else { continue }
            targets.append(ReaderAIWikiTarget(
                target: ref.target,
                label: ref.label,
                path: resolved.path,
                title: resolved.title
            ))
        }
        return targets
    }

    private func readerAISourcePaths(for entry: Entry) -> [String] {
        var paths: [String] = []
        if let slug = pdfEntry(for: entry, in: entries)?.pdfSlug, !slug.isEmpty {
            paths.append("sources/\(slug).pdf")
        }
        for slug in sourceSlugCandidates(for: entry, in: entries) where client.hasTranslation(slug: slug) {
            paths.append("processing/translations/\(slug)-zh.pdf")
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    var canOpenPDF: Bool { openPDFSlug != nil }

    var canOpenTranslation: Bool { openTranslationSlug != nil }

    // MARK: object creation

    func importImage(from url: URL) async {
        writeError = nil
        do {
            let entry = try await client.createImageObject(from: url, title: nil)
            catalog.mutateEntries { $0.append(entry) }
            rebuildIndexDerived()
            select(pane: .type(.image))
            await open(entry.path)
            print("[marple] imported image \(entry.path)")
        } catch {
            writeError = "\(error)"
            print("[marple] import image FAILED \(url.path): \(error)")
        }
    }

    // MARK: note creation

    func newIdeaNote() async {
        let draft = NoteBuilder.ideaNote()
        await createAndReveal(draft, entry: ideaEntry(from: draft))
    }

    func newAnnotation(for entry: Entry) async {
        let target = annotationTarget(for: entry, in: entries)
        let draft = NoteBuilder.annotation(target: target)
        await createAndReveal(draft, entry: annotationEntry(from: draft, target: target))
    }

    func newAnnotationForOpenDoc() async {
        guard let e = openEntry else { return }
        await newAnnotation(for: e)
    }

    /// POST the draft, optimistically add its Entry, reveal it, then open it in
    /// the external editor (this is a reader — the empty note is edited outside).
    private func createAndReveal(_ draft: NoteDraft, entry: Entry) async {
        writeError = nil
        do {
            try await client.createNote(path: draft.path, text: draft.text)
            catalog.mutateEntries { $0.append(entry) }
            rebuildIndexDerived(); recomputeVisible()
            await open(draft.path)
            await openExternally()
            print("[marple] created \(draft.path)")
        } catch {
            writeError = "\(error)"
            print("[marple] create FAILED \(draft.path): \(error)")
        }
    }

    private func ideaEntry(from draft: NoteDraft) -> Entry {
        Entry(path: draft.path, type: .note, title: draft.title, author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }

    private func annotationEntry(from draft: NoteDraft, target: Entry) -> Entry {
        Entry(path: draft.path, type: .note, title: draft.title, author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false, annotates: target.path)
    }

    // MARK: trash

    func loadTrash() async {
        do { trashItems = try await client.listTrash() }
        catch { print("[marple] listTrash FAILED: \(error)") }
    }

    /// Soft-delete `path`: backend moves it to .trash, then optimistically drop
    /// it from the in-memory index. If the active tab shows it, clear the doc.
    func moveToTrash(_ path: String) async {
        writeError = nil
        do {
            _ = try await client.moveToTrash(path: path)
            let wasOpen = (openPath == path)
            catalog.mutateEntries { $0.removeAll { $0.path == path } }
            rebuildIndexDerived()
            if wasOpen, let id = activeTabID {
                await closeTab(id)   // closeTab re-syncs the list + reader
            } else {
                recomputeVisible()
            }
            await loadTrash()
            print("[marple] trashed \(path)")
        } catch {
            writeError = "\(error)"
            print("[marple] trash FAILED \(path): \(error)")
        }
    }

    /// Restore re-adds a file we can't cheaply describe → reload the whole index
    /// (rare action; loadIndex also refreshes the trash list).
    func restoreTrash(_ name: String) async {
        writeError = nil
        do {
            _ = try await client.restoreTrash(name: name)
            await loadIndex()
            print("[marple] restored \(name)")
        } catch {
            writeError = "\(error)"
            print("[marple] restore FAILED \(name): \(error)")
        }
    }

    func purgeTrash(_ name: String) async {
        writeError = nil
        do {
            try await client.purgeTrash(name: name)
            trashItems.removeAll { $0.name == name }
            print("[marple] purged \(name)")
        } catch {
            writeError = "\(error)"
            print("[marple] purge FAILED \(name): \(error)")
        }
    }

    // MARK: metadata write-back

    /// Fetch fresh → patch → PUT → apply-on-success. Re-reading the file avoids
    /// writing a stale cached copy; on failure nothing local changes.
    private func applyPatch(field: String,
                            _ patch: @escaping (String) -> String,
                            local: @escaping (Entry) -> Entry) async {
        guard let path = openPath else { return }
        savingField = field; writeError = nil
        defer { savingField = nil }
        do {
            try await metadataWriter.write(path: path, applying: patch)
            catalog.mutateEntries { es in
                if let i = es.firstIndex(where: { $0.path == path }) {
                    es[i] = local(es[i])
                }
            }
            rebuildIndexDerived()   // themes/rating affect themeIndex/filters/counts
            recomputeVisible()
            recomputeOpenDerived()
            print("[marple] wrote \(field) -> \(path)")
        } catch {
            writeError = "\(error)"
            print("[marple] write FAILED \(field) \(path): \(error)")
        }
    }

    func setRating(_ stars: Int?) async {
        let n = stars ?? 0
        let value = n > 0 ? String(min(5, n)) : nil
        await applyPatch(field: "rating",
            { FrontmatterPatch.setScalar($0, key: "rating", value: value, numeric: true) },
            local: { $0.with(ratingScore: Double(max(0, n))) })
    }

    func setYear(_ text: String?) async {
        let val = normalize(text)
        await applyPatch(field: "year",
            { FrontmatterPatch.setScalar($0, key: "year", value: val, numeric: true) },
            local: { $0.with(year: .some(val)) })
    }

    func setTitle(_ text: String?) async {
        let val = normalize(text)
        await applyPatch(field: "title",
            { FrontmatterPatch.setScalar($0, key: "title", value: val) },
            local: { $0.with(title: .some(val)) })
    }

    /// Set the author list. Empty list → clear both `author:` and `authors:`
    /// (legacy alias) frontmatter keys; non-empty → write canonical block
    /// list under `author:` per SPEC §5.2.
    ///
    /// A `talk` stores its presenters under `speaker:` and an `image` its
    /// makers under `creator:` (not `author:`), so for those types the same
    /// edit writes their own key instead — the inspector reuses the authors
    /// row for 讲者/创作者, and the indexer folds the key back into `author`
    /// on reload.
    func setAuthor(_ authors: [String]) async {
        let cleaned = authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let key: String
        switch openEntry?.type {
        case .talk:  key = "speaker"
        case .image: key = "creator"
        default:     key = "author"
        }
        await applyPatch(
            field: key,
            { raw in
                if cleaned.isEmpty {
                    if key != "author" {
                        return FrontmatterPatch.removeKey(raw, key: key)
                    }
                    // Double-clear: vault has both `author:` and `authors:`
                    // historic spellings; drop both to guarantee absence.
                    return FrontmatterPatch.removeKey(
                        FrontmatterPatch.removeKey(raw, key: "author"),
                        key: "authors"
                    )
                }
                if key != "author" {
                    return FrontmatterPatch.setSequence(raw, key: key, values: cleaned)
                }
                // Also drop the alias key so the canonical `author:` is the
                // only one present after the write.
                let withoutAlias = FrontmatterPatch.removeKey(raw, key: "authors")
                return FrontmatterPatch.setSequence(withoutAlias, key: "author", values: cleaned)
            },
            local: { $0.with(author: cleaned) }
        )
    }

    /// Set an image's creation/capture date — writes the `date:` frontmatter
    /// key, which the indexer folds into the `created` column (QUA-175).
    func setImageDate(_ text: String?) async {
        let val = normalize(text)
        await applyPatch(field: "date",
            { FrontmatterPatch.setScalar($0, key: "date", value: val) },
            local: { $0.with(created: .some(val)) })
    }

    /// Author-profile entry whose title matches `name`. Forwards to
    /// NameResolver (exact tier = the old scan; folded tier per QUA-218 PR2
    /// approved diffs ①②). Used by the Inspector author chips.
    func authorProfile(for name: String) -> Entry? {
        NameResolver.authorProfile(named: name, in: entries)
    }

    func setSource(_ text: String?) async {
        let val = normalize(text)
        await applyPatch(field: "source",
            { FrontmatterPatch.setScalar($0, key: "source", value: val) },
            local: { $0.with(source: .some(val)) })
    }

    func setDoi(_ text: String?) async {
        let val = normalize(text)
        await applyPatch(field: "doi",
            { FrontmatterPatch.setScalar($0, key: "doi", value: val) },
            local: { $0.with(doi: .some(val)) })
    }

    func addThemes(_ raw: String) async {
        let add = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !add.isEmpty, let cur = openEntry?.themes else { return }
        var next = cur
        for t in add where !next.contains(t) { next.append(t) }
        await applyPatch(field: "themes",
            { FrontmatterPatch.setThemes($0, next) },
            local: { $0.with(themes: next) })
    }

    func removeTheme(_ theme: String) async {
        guard let cur = openEntry?.themes else { return }
        let next = cur.filter { $0 != theme }
        await applyPatch(field: "themes",
            { FrontmatterPatch.setThemes($0, next) },
            local: { $0.with(themes: next) })
    }

    private func normalize(_ text: String?) -> String? {
        let t = text?.trimmingCharacters(in: .whitespaces)
        return (t?.isEmpty ?? true) ? nil : t
    }
}
