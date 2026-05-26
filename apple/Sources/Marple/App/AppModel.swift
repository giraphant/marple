import Foundation
import MarpleKit
import Observation

/// Middle-column display mode for the entry list.
enum BrowseMode: String, CaseIterable, Sendable { case list, grid }

@Observable @MainActor
final class AppModel {
    let client: VaultClient
    private(set) var entries: [Entry] = []
    var status: String = ""

    /// Card grid vs single-column list. Pure UI toggle; no derived cache depends on it.
    var browseMode: BrowseMode = .grid { didSet { persist() } }

    // Browse axis: which category list the sidebar shows. Separate from tabs —
    // selecting a category never touches the open document tabs.
    private(set) var browsePane: Pane = .type(.paperAnalysis) { didSet { persist() } }

    // Browsing the category list (true) vs reading an open document tab (false).
    private(set) var isBrowsing: Bool = true { didSet { persist() } }

    // Open DOCUMENT tabs (browser-style), nil until the first doc is opened and back
    // to nil when the last closes. Each tab carries its own back/forward history
    // (e.g. following wikilinks). Categories are NOT tabs.
    private(set) var workspace: Workspace? { didSet { persist() } }

    var pane: Pane { browsePane }
    var openPath: String? { isBrowsing ? nil : workspace?.activeTab.location.openPath }
    var tabs: [NavTab] { workspace?.tabs ?? [] }
    var tabGroups: [TabGroup] { workspace?.tabGroups ?? [] }
    var tabRootNodes: [TabNode] { workspace?.rootNodes ?? [] }
    var activeTabID: NavTab.ID? { isBrowsing ? nil : workspace?.activeID }
    var canGoBack: Bool { !isBrowsing && (workspace?.activeTab.history.canGoBack ?? false) }
    var canGoForward: Bool { !isBrowsing && (workspace?.activeTab.history.canGoForward ?? false) }

    /// Mutate the optional doc-tab workspace in place (struct value semantics).
    private func mutateWorkspace(_ f: (inout Workspace) -> Void) {
        guard var ws = workspace else { return }
        f(&ws)
        workspace = ws
    }

    // The doc whose body/blocks/derived caches are currently loaded — lets tab and
    // history switches skip a re-fetch when the doc hasn't actually changed.
    private var loadedDocPath: String?

    // Browse state (mutate via the intent methods below so derived caches refresh)
    private(set) var sortClauses: [SortClause] = [] { didSet { persist() } }
    private(set) var filterClauses: [FilterClause] = [] { didSet { persist() } }
    private(set) var filterMatch: FilterMatch = .all { didSet { persist() } }
    private(set) var searchText: String = ""
    private var searchHits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?
    private var matchTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?

    /// Per-result matched body lines for the current list search (keyed by path).
    /// Populated off-main after the search settles; rows read from it.
    private(set) var searchMatches: [String: BodyMatches] = [:]
    /// The query `searchMatches` was computed for. A matched-line tap uses THIS
    /// (not the live `searchText`) so a tap during the debounce window stays
    /// self-consistent — anchor/ordinal/query always describe the same search.
    private(set) var searchMatchQuery: String = ""
    /// Result rows whose "再显示 N 个匹配项" expander has been opened.
    var matchExpanded: Set<String> = []

    // Derived caches — recomputed only when their inputs change, never in a view body.
    private(set) var counts: [EntryType: Int] = [:]
    private(set) var themeIndex: [ThemeCount] = []
    private(set) var visibleEntries: [Entry] = []
    private(set) var authorIndex: [String: [Entry]] = [:]
    private(set) var annotationIndex: [String: [Entry]] = [:]
    /// Prebuilt field-weighted index for the command palette's 快速 mode (rebuilt
    /// whenever `entries` changes, like the other derived caches). Carries a
    /// trigram inverted index so per-keystroke ranking only scores hundreds of
    /// candidate docs instead of 15k full-scans.
    private(set) var searchIndex: SearchIndex = .empty

    // Trash list (loaded lazily; sidebar badge reads .count).
    private(set) var trashItems: [TrashItem] = []

    // Reading state
    var openBlocks: [RenderBlock] = []

    // Open-doc derived caches (recomputed on open / reload, not per render).
    private(set) var openEntry: Entry?
    private(set) var openBody: String = ""
    private(set) var openOutline: [OutlineItem] = []
    private(set) var openStats: DocStats?
    private(set) var openRelations: Relations?
    private(set) var openBook: BookContext?

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

    // Metadata write state.
    private(set) var savingField: String?
    var writeError: String?

    private let stateStore: StateStore?
    private let semantic: (any SemanticBackend)?

    /// True when a vector index exists, so 深度 (semantic) mode can run.
    var semanticAvailable: Bool { semantic != nil }

    /// User-customised sidebar type order. Defaults to the canonical order; persisted
    /// separately from workspace state via UserDefaults.
    private(set) var typeOrder: [EntryType] = EntryType.modeled {
        didSet { persistTypeOrder() }
    }

    init(client: VaultClient, stateStore: StateStore? = nil, semantic: (any SemanticBackend)? = nil) {
        self.client = client
        self.stateStore = stateStore
        self.semantic = semantic
        if let s = stateStore?.load() {
            browsePane = s.browsePane
            workspace = s.makeWorkspace()
            isBrowsing = workspace == nil ? true : s.isBrowsing
            sortClauses = s.sortClauses
            filterClauses = s.filterClauses
            filterMatch = s.filterMatch
            browseMode = BrowseMode(rawValue: s.browseMode) ?? .grid
        }
        loadTypeOrder()
    }

    /// Save the current place (browse category + doc tabs + controls). Cheap — a small
    /// JSON blob to UserDefaults; invoked from the state properties' didSet, so every
    /// mutation auto-saves without per-intent hooks.
    private func persist() {
        guard let stateStore else { return }
        let ws = workspace
        let savedTabs = ws?.tabs.map { PersistedTab(location: $0.location, pinned: $0.pinned, customTitle: $0.customTitle) } ?? []
        let idx = ws.flatMap { w in w.tabs.firstIndex { $0.id == w.activeID } } ?? 0
        stateStore.save(PersistedState(
            browsePane: browsePane,
            isBrowsing: isBrowsing,
            tabs: savedTabs,
            activeIndex: idx,
            sortClauses: sortClauses,
            filterClauses: filterClauses,
            filterMatch: filterMatch,
            browseMode: browseMode.rawValue,
            currentSpace: ws.map { PersistedWorkspaceSpace(tree: $0.treeSnapshot) }))
    }

    // MARK: type order persistence

    private static let typeOrderKey = "marple.typeOrder"

    private func loadTypeOrder() {
        guard let data = UserDefaults.standard.data(forKey: Self.typeOrderKey),
              let decoded = try? JSONDecoder().decode([EntryType].self, from: data) else { return }
        var order = decoded
        // Append any new modeled types not yet in the saved order.
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

    // MARK: derived recompute

    /// Rebuild the index-wide caches. Split into two phases:
    /// - immediate: counts + themeIndex (cheap; the sidebar needs them right away)
    /// - deferred: authorIndex/annotationIndex/searchIndex (heavy; only needed by
    ///   the reading view's relations panel and the Cmd-K palette, neither of
    ///   which is exercised in the first few hundred ms after launch)
    private func rebuildIndexDerived() {
        var c: [EntryType: Int] = [:]
        for e in entries { c[e.type, default: 0] += 1 }
        counts = c
        themeIndex = themeCounts(entries)
        scheduleDeferredDerivedRebuild()
    }

    /// Build the heavy derived caches (authors, annotations, search index) on a
    /// background task and publish them on the main actor when done. If
    /// `entries` changes again before this task completes, the in-flight task
    /// is cancelled and stale dispatch blocks are vetoed by generation counter
    /// — only the latest snapshot wins.
    private var deferredDerivedTask: Task<Void, Never>?
    private var derivedGeneration: Int = 0
    private func scheduleDeferredDerivedRebuild() {
        deferredDerivedTask?.cancel()
        derivedGeneration &+= 1
        let generation = derivedGeneration
        let snapshot = entries
        deferredDerivedTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let authors = buildAuthorIndex(snapshot)
                let annot = buildAnnotationIndex(snapshot)
                let search = buildSearchIndex(snapshot)
                return (authors, annot, search)
            }.value
            if Task.isCancelled { return }
            // Hop to the next main-runloop tick (not MainActor.run, which can
            // run synchronously inside the current render pass and triggered an
            // NSTableView reentrant-delegate warning when @Observable
            // invalidation cascaded back into the table mid-render).
            //
            // DispatchQueue.main.async can't be cancelled, so guard the
            // assignment with the generation counter: any newer rebuild bumps
            // `derivedGeneration` and this stale block becomes a no-op.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.derivedGeneration == generation else { return }
                self.authorIndex = result.0
                self.annotationIndex = result.1
                self.searchIndex = result.2
                if self.openEntry != nil { self.recomputeOpenDerived() }
            }
        }
    }

    /// Recompute the open document's outline / stats / entry / relations. O(n) over
    /// the index for relations; runs on open / reload / metadata write, not per render.
    private func recomputeOpenDerived() {
        openEntry = entries.first { $0.path == openPath }
        let preprocessed = Wikilink.preprocessForRendering(openBody)
        let rendered = MarkdownRenderer.render(preprocessed, style: RenderStyle(
            size: ReadingDefaults.fontSize, design: .sans, lineHeight: ReadingDefaults.lineHeight
        ))
        openOutline = outline(from: rendered.headings)
        openStats = openBody.isEmpty ? nil : computeDocStats(openBody)
        if let e = openEntry {
            openRelations = relations(for: e, in: entries,
                                      authorIndex: authorIndex, annotationIndex: annotationIndex)
            openBook = bookContext(for: e, in: entries)
        } else {
            openRelations = nil
            openBook = nil
        }
    }

    /// Rebuild the middle-column list. Search hits are a cheap direct swap; the pane
    /// subset (filter→sort over ~15k entries) is computed OFF the main thread and
    /// applied back on main, with stale rebuilds dropped via task cancellation. This
    /// keeps clearing search / switching panes off the keystroke so text input never
    /// blocks — mirrors NetNewsWire/FSNotes/CodeEdit list-search discipline (don't
    /// re-filter synchronously in the input handler).
    private func recomputeVisible() {
        recomputeTask?.cancel()
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            visibleEntries = searchHits.map(\.entry)
            return
        }
        let snapshot = entries
        let pane = self.pane
        let filters = filterClauses
        let match = filterMatch
        let sorts = sortClauses
        recomputeTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                sortEntries(applyFilters(entriesForPane(pane, in: snapshot), filters, match: match),
                            by: sorts)
            }.value
            guard !Task.isCancelled else { return }
            self?.visibleEntries = result
        }
    }

    // MARK: actions

    func loadIndex() async {
        do {
            entries = try await client.index()
            status = "\(entries.count) entries"
            rebuildIndexDerived()
            recomputeVisible()
            if openPath != loadedDocPath { await loadDoc(openPath) }
            await loadTrash()
            print("[marple] index loaded: \(entries.count) entries")
        } catch {
            status = "index failed: \(error)"
            print("[marple] index FAILED: \(error)")
        }
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

    func setSort(_ clauses: [SortClause]) {
        sortClauses = clauses
        recomputeVisible()
    }

    func setFilters(_ clauses: [FilterClause], match: FilterMatch = .all) {
        filterClauses = clauses
        filterMatch = match
        recomputeVisible()
    }

    func setSearchText(_ text: String) {
        searchText = text
        runSearch()
    }

    /// Debounced server search scoped to the current type pane (nil type → all).
    private func runSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = []; clearSearchMatches(); recomputeVisible(); return }
        let type: EntryType? = { if case .type(let t) = pane { return t } else { return nil } }()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let hits = try await self?.client.search(SearchQuery(q: q, type: type)) ?? []
                if Task.isCancelled { return }
                self?.searchHits = hits
                self?.recomputeVisible()
                self?.computeSearchMatches(query: q, paths: hits.map(\.entry.path))
                print("[marple] search '\(q)' -> \(hits.count) hits")
            } catch {
                self?.status = "search failed: \(error)"
                print("[marple] search FAILED '\(q)': \(error)")
            }
        }
    }

    private func clearSearchMatches() {
        matchTask?.cancel()
        searchMatches = [:]
        searchMatchQuery = ""
        matchExpanded = []
    }

    /// Load each result's stripped body off-main and compute its matched lines.
    /// Bounded to the hit set (≤ search limit); cancellable and query-versioned so a
    /// stale load can never attach excerpts to a newer query's rows. Matches the
    /// stripped body (not the raw file) so frontmatter can't create phantom matches.
    private func computeSearchMatches(query: String, paths: [String]) {
        matchTask?.cancel()
        matchExpanded = []
        searchMatches = [:]
        let client = self.client
        matchTask = Task { [weak self] in
            var result: [String: BodyMatches] = [:]
            for path in paths {
                if Task.isCancelled { return }
                guard let raw = try? await client.entryText(path: path) else { continue }
                let body = Frontmatter.split(raw).body
                let m = bodyLineMatches(body: body, query: query)
                if !m.lines.isEmpty { result[path] = m }
            }
            if Task.isCancelled { return }
            guard let self,
                  self.searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            self.searchMatches = result
            self.searchMatchQuery = query
        }
    }

    /// Toggle a result row's "再显示 N 个匹配项" expander.
    func toggleMatchExpanded(_ path: String) {
        if matchExpanded.contains(path) { matchExpanded.remove(path) }
        else { matchExpanded.insert(path) }
    }

    /// Open `path` from a clicked search matched-line: opens browser-style (in-place
    /// while reading, new tab while browsing) and tells the reader to highlight the
    /// query + scroll to the clicked line.
    func openMatchedLine(path: String, query: String, ordinal: Int, anchor: String) async {
        await open(path)
        openSearchQuery = query
        matchJump = MatchJump(query: query, anchor: anchor, ordinal: ordinal)
    }

    private func clearReaderHighlight() {
        openSearchQuery = nil
        matchJump = nil
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
            mutateWorkspace { $0.navigateActive(to: NavLocation(pane: browsePane, openPath: path)) }
            isBrowsing = false
            await loadDoc(path)
        }
    }

    private func openNewTab(_ path: String) async {
        let loc = NavLocation(pane: browsePane, openPath: path)
        if workspace == nil {
            workspace = Workspace(initial: loc)
        } else {
            mutateWorkspace { $0.newTab(loc) }
        }
        isBrowsing = false
        await loadDoc(path)
    }

    /// Fetch + render the doc at `path` into the open-doc caches. `nil` clears them.
    /// Always loads (no `loadedDocPath` guard) so it doubles as the FSEvents refresh.
    private func loadDoc(_ path: String?) async {
        writeError = nil
        guard let path else {
            openBlocks = []; openBody = ""; loadedDocPath = nil
            recomputeOpenDerived()
            return
        }
        do {
            let raw = try await client.entryText(path: path)
            openBody = Frontmatter.split(raw).body
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
        searchText = ""; searchHits = []; searchTask?.cancel()
        clearSearchMatches(); clearReaderHighlight()
        recomputeVisible()
        if openPath != loadedDocPath { await loadDoc(openPath) }
    }

    func reloadOpen() async {
        if let p = openPath { print("[marple] watcher reload \(p)"); await loadDoc(p) }
    }

    func follow(_ target: String) async {
        guard let hit = WikiResolver.resolve(target, in: entries) else {
            status = "unresolved [[\(target)]]"
            print("[marple] follow [[\(target)]] -> UNRESOLVED")
            return
        }
        print("[marple] follow [[\(target)]] -> \(hit.path)")
        clearReaderHighlight()
        // Wikilink follow stays WITHIN the current tab (per-tab history); if we're
        // browsing (no active tab), open it as a new tab instead.
        if !isBrowsing, workspace != nil {
            mutateWorkspace { $0.navigateActive(to: NavLocation(pane: browsePane, openPath: hit.path)) }
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

    func selectTab(_ id: NavTab.ID) async {
        mutateWorkspace { $0.select(id) }
        isBrowsing = false
        await syncToActiveLocation()
    }

    func selectTab(index: Int) async {
        mutateWorkspace { $0.selectIndex(index) }
        isBrowsing = false
        await syncToActiveLocation()
    }

    func selectNextTab() async { mutateWorkspace { $0.selectRelative(1) }; isBrowsing = false; await syncToActiveLocation() }
    func selectPrevTab() async { mutateWorkspace { $0.selectRelative(-1) }; isBrowsing = false; await syncToActiveLocation() }

    /// Close a document tab. Closing the last one drops back to the browse list.
    func closeTab(_ id: NavTab.ID) async {
        guard var ws = workspace else { return }
        ws.closeTab(id)
        if ws.tabs.isEmpty {
            workspace = nil
            isBrowsing = true
        } else {
            workspace = ws
        }
        await syncToActiveLocation()
    }

    /// Close the active tab (⌘W). Skips a pinned tab.
    func closeActiveTab() async {
        guard !isBrowsing, let ws = workspace, !ws.activeTab.pinned, let id = activeTabID else { return }
        await closeTab(id)
    }

    /// Close every tab except `keep` and any pinned tabs.
    func closeOtherTabs(_ keep: NavTab.ID) async {
        guard var ws = workspace else { return }
        let toClose = ws.tabs.filter { $0.id != keep && !$0.pinned }.map(\.id)
        guard !toClose.isEmpty else { return }
        for id in toClose { ws.closeTab(id) }
        ws.select(keep)
        workspace = ws
        await syncToActiveLocation()
    }

    /// Close every tab in `ids` skipping pinned. Empties drop back to browse mode
    /// the same way the single-tab close does.
    func closeTabs(_ ids: Set<NavTab.ID>) async {
        guard var ws = workspace else { return }
        ws.closeTabs(ids)
        if ws.tabs.isEmpty {
            workspace = nil
            isBrowsing = true
        } else {
            workspace = ws
        }
        await syncToActiveLocation()
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

    func togglePin(_ id: NavTab.ID) { mutateWorkspace { $0.togglePin(id) } }

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

    func tabTitle(_ tab: NavTab) -> String {
        if let customTitle = tab.customTitle { return customTitle }
        let loc = tab.location
        if let p = loc.openPath {
            return entries.first { $0.path == p }?.title ?? (p as NSString).lastPathComponent
        }
        switch loc.pane {
        case .type(let t):     return t.label
        case .theme(let name): return "#\(name)"
        case .themesIndex:     return "主题"
        case .trash:           return "回收站"
        }
    }

    func tabIsDoc(_ tab: NavTab) -> Bool { tab.location.openPath != nil }

    func openExternally() async {
        guard let p = openPath else { return }
        let app = UserDefaults.standard.string(forKey: SettingsKeys.externalEditor) ?? ""
        do {
            try await client.openInEditor(path: p, app: app)
            print("[marple] openInEditor \(p) app='\(app)'")
        } catch {
            status = "open-in-editor failed: \(error)"
            print("[marple] openInEditor FAILED \(p): \(error)")
        }
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
            status = "open-PDF failed: \(error)"
            print("[marple] openPDF FAILED \(slug): \(error)")
        }
    }

    func openTranslation() async {
        guard let slug = openTranslationSlug else { return }
        do {
            try await client.openTranslation(slug: slug)
            print("[marple] openTranslation \(slug)")
        } catch {
            status = "open-translation failed: \(error)"
            print("[marple] openTranslation FAILED \(slug): \(error)")
        }
    }

    var canOpenPDF: Bool { openPDFSlug != nil }

    var canOpenTranslation: Bool { openTranslationSlug != nil }

    // MARK: object creation

    func importImage(from url: URL) async {
        writeError = nil
        do {
            let entry = try await client.createImageObject(from: url, title: nil)
            entries.append(entry)
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
        let target = annotationAnchor(for: entry, in: entries)
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
            entries.append(entry)
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
        Entry(path: draft.path, type: .note, title: draft.title, author: nil, year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }

    private func annotationEntry(from draft: NoteDraft, target: Entry) -> Entry {
        Entry(path: draft.path, type: .note, title: draft.title, author: nil, year: nil,
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
            entries.removeAll { $0.path == path }
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
            let fresh = try await client.entryText(path: path)
            let next = patch(fresh)
            try await client.writeFile(path: path, text: next)
            if let i = entries.firstIndex(where: { $0.path == path }) {
                entries[i] = local(entries[i])
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
        let value = n > 0 ? String(repeating: "★", count: min(5, n)) : nil
        await applyPatch(field: "rating",
            { FrontmatterPatch.setScalar($0, key: "rating", value: value) },
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

    func setAuthor(_ text: String?) async {
        let val = normalize(text)
        await applyPatch(field: "author",
            { FrontmatterPatch.setScalar($0, key: "author", value: val) },
            local: { $0.with(author: .some(val)) })
    }

    /// Author-profile entry whose title matches `name` (case-insensitive). Used
    /// by the Inspector so each chip in a multi-author row can navigate to its
    /// own profile. Linear scan — call frequency is bounded by inspector renders.
    func authorProfile(for name: String) -> Entry? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return entries.first {
            $0.type == .authorProfile && ($0.title ?? "").lowercased() == key
        }
    }

    func setSource(_ text: String?) async {
        let val = normalize(text)
        await applyPatch(field: "source",
            { FrontmatterPatch.setScalar($0, key: "source", value: val) },
            local: { $0.with(source: .some(val)) })
    }

    func setTopic(_ text: String?) async {
        let val = normalize(text)
        await applyPatch(field: "topic",
            { FrontmatterPatch.setScalar($0, key: "topic", value: val) },
            local: { $0.with(topic: .some(val)) })
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
