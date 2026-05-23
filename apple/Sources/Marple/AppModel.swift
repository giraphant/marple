import Foundation
import MarpleKit
import Observation

@Observable @MainActor
final class AppModel {
    let client: VaultClient
    private(set) var entries: [Entry] = []
    var status: String = ""

    // Tabs + per-tab back/forward history. `pane`/`openPath` are derived from the
    // active tab's current location; mutate via the navigation intents below.
    private(set) var workspace = Workspace(initial: NavLocation(pane: .type(.paperAnalysis)))

    var pane: Pane { workspace.activeTab.location.pane }
    var openPath: String? { workspace.activeTab.location.openPath }
    var tabs: [NavTab] { workspace.tabs }
    var activeTabID: NavTab.ID { workspace.activeID }
    var canGoBack: Bool { workspace.activeTab.history.canGoBack }
    var canGoForward: Bool { workspace.activeTab.history.canGoForward }

    // The doc whose body/blocks/derived caches are currently loaded — lets tab and
    // history switches skip a re-fetch when the doc hasn't actually changed.
    private var loadedDocPath: String?

    // Browse state (mutate via the intent methods below so derived caches refresh)
    private(set) var sortClauses: [SortClause] = []
    private(set) var filterClauses: [FilterClause] = []
    private(set) var filterMatch: FilterMatch = .all
    private(set) var searchText: String = ""
    private var searchHits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?

    // Derived caches — recomputed only when their inputs change, never in a view body.
    private(set) var counts: [EntryType: Int] = [:]
    private(set) var themeIndex: [ThemeCount] = []
    private(set) var visibleEntries: [Entry] = []
    private(set) var authorIndex: [String: [Entry]] = [:]
    private(set) var annotationIndex: [String: [Entry]] = [:]

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

    // Inspector → reader scroll channel; an outline tap sets this, DocView observes.
    var scrollTarget: Int?

    // Metadata write state.
    private(set) var savingField: String?
    var writeError: String?

    init(client: VaultClient) { self.client = client }

    // MARK: derived recompute

    /// Rebuild the index-wide caches (counts + theme index). O(n) over all entries;
    /// runs once per index load, not per render.
    private func rebuildIndexDerived() {
        var c: [EntryType: Int] = [:]
        for e in entries { c[e.type, default: 0] += 1 }
        counts = c
        themeIndex = themeCounts(entries)
        authorIndex = buildAuthorIndex(entries)
        annotationIndex = buildAnnotationIndex(entries)
    }

    /// Recompute the open document's outline / stats / entry / relations. O(n) over
    /// the index for relations; runs on open / reload / metadata write, not per render.
    private func recomputeOpenDerived() {
        openEntry = entries.first { $0.path == openPath }
        openOutline = outline(from: openBlocks)
        openStats = openBody.isEmpty ? nil : computeDocStats(openBody)
        if let e = openEntry {
            openRelations = relations(for: e, in: entries,
                                      authorIndex: authorIndex, annotationIndex: annotationIndex)
        } else {
            openRelations = nil
        }
    }

    /// Rebuild the middle-column list: search hits when searching, else the pane
    /// subset run through filters then sort. Call after any browse-state change.
    private func recomputeVisible() {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            visibleEntries = searchHits.map(\.entry)
            return
        }
        let base = entriesForPane(pane, in: entries)
        let filtered = applyFilters(base, filterClauses, match: filterMatch)
        visibleEntries = sortEntries(filtered, by: sortClauses)
    }

    // MARK: actions

    func loadIndex() async {
        do {
            entries = try await client.index()
            status = "\(entries.count) entries"
            rebuildIndexDerived()
            recomputeVisible()
            await loadTrash()
            print("[marple] index loaded: \(entries.count) entries")
        } catch {
            status = "index failed: \(error)"
            print("[marple] index FAILED: \(error)")
        }
    }

    func select(pane newPane: Pane) {
        workspace.navigateActive(to: NavLocation(pane: newPane, openPath: openPath))
        searchText = ""; searchHits = []
        recomputeVisible()
        if case .trash = newPane { Task { await loadTrash() } }
        print("[marple] pane -> \(newPane)")
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
        guard !q.isEmpty else { searchHits = []; recomputeVisible(); return }
        let type: EntryType? = { if case .type(let t) = pane { return t } else { return nil } }()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let hits = try await self?.client.search(SearchQuery(q: q, type: type)) ?? []
                if Task.isCancelled { return }
                self?.searchHits = hits
                self?.recomputeVisible()
                print("[marple] search '\(q)' -> \(hits.count) hits")
            } catch {
                self?.status = "search failed: \(error)"
                print("[marple] search FAILED '\(q)': \(error)")
            }
        }
    }

    /// Navigate the active tab to `path` (pushes history) and load it.
    func open(_ path: String) async {
        workspace.navigateActive(to: NavLocation(pane: pane, openPath: path))
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
        searchText = ""; searchHits = []
        recomputeVisible()
        if openPath != loadedDocPath { await loadDoc(openPath) }
    }

    func reloadOpen() async {
        if let p = openPath { print("[marple] watcher reload \(p)"); await loadDoc(p) }
    }

    func follow(_ target: String) async {
        if let hit = WikiResolver.resolve(target, in: entries) {
            print("[marple] follow [[\(target)]] -> \(hit.path)")
            await open(hit.path)
        } else {
            status = "unresolved [[\(target)]]"
            print("[marple] follow [[\(target)]] -> UNRESOLVED")
        }
    }

    // MARK: history + tabs

    func goBack() async {
        guard canGoBack else { return }
        workspace.backActive()
        print("[marple] back -> \(openPath ?? "\(pane)")")
        await syncToActiveLocation()
    }

    func goForward() async {
        guard canGoForward else { return }
        workspace.forwardActive()
        print("[marple] forward -> \(openPath ?? "\(pane)")")
        await syncToActiveLocation()
    }

    /// New tab browsing the current pane, no open doc.
    func newTab() async {
        workspace.newTab(NavLocation(pane: pane, openPath: nil))
        print("[marple] new tab (\(tabs.count) total)")
        await syncToActiveLocation()
    }

    /// Open `path` in a new tab (current pane) and activate it.
    func openInNewTab(_ path: String) async {
        workspace.newTab(NavLocation(pane: pane, openPath: path))
        print("[marple] open in new tab \(path)")
        await syncToActiveLocation()
    }

    func selectTab(_ id: NavTab.ID) async {
        workspace.select(id)
        await syncToActiveLocation()
    }

    func selectTab(index: Int) async {
        workspace.selectIndex(index)
        await syncToActiveLocation()
    }

    func selectNextTab() async { workspace.selectRelative(1); await syncToActiveLocation() }
    func selectPrevTab() async { workspace.selectRelative(-1); await syncToActiveLocation() }

    /// Close a specific tab (× / context menu). Won't close the last remaining tab.
    func closeTab(_ id: NavTab.ID) async {
        guard tabs.count > 1 else { return }
        workspace.closeTab(id)
        await syncToActiveLocation()
    }

    /// Close the active tab (⌘W). Skips a pinned tab and won't close the last one.
    func closeActiveTab() async {
        guard tabs.count > 1, !workspace.activeTab.pinned else { return }
        await closeTab(activeTabID)
    }

    /// Close every tab except `keep` and any pinned tabs.
    func closeOtherTabs(_ keep: NavTab.ID) async {
        let toClose = tabs.filter { $0.id != keep && !$0.pinned }.map(\.id)
        guard !toClose.isEmpty else { return }
        for id in toClose { workspace.closeTab(id) }
        workspace.select(keep)
        await syncToActiveLocation()
    }

    func togglePin(_ id: NavTab.ID) { workspace.togglePin(id) }

    func setTabOrder(_ ids: [NavTab.ID]) { workspace.reorder(ids) }

    // MARK: tab labels

    func tabTitle(_ tab: NavTab) -> String {
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
        do {
            try await client.openInEditor(path: p, app: "")
            print("[marple] openInEditor \(p)")
        } catch {
            status = "open-in-editor failed: \(error)"
            print("[marple] openInEditor FAILED \(p): \(error)")
        }
    }

    // MARK: note creation

    func newIdeaNote() async {
        let draft = NoteBuilder.ideaNote()
        await createAndReveal(draft, entry: ideaEntry(from: draft))
    }

    func newAnnotation(for entry: Entry) async {
        let draft = NoteBuilder.annotation(target: entry)
        await createAndReveal(draft, entry: annotationEntry(from: draft, target: entry))
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
            entries.removeAll { $0.path == path }
            if openPath == path {
                workspace.navigateActive(to: NavLocation(pane: pane, openPath: nil))
                await loadDoc(nil)
            }
            rebuildIndexDerived(); recomputeVisible()
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
