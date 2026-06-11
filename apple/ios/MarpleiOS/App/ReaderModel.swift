import Foundation
import SwiftUI
import MarpleKit

/// The Mac open-tab display types + resolution now live in MarpleKit
/// (`SessionResolver`), shared with the Mac app (QUA-218 PR4). These aliases keep
/// the iOS sidebar's call sites unchanged.
typealias MacTabNode = ResolvedSessionNode
typealias MacSpaceTabs = ResolvedSessionSpace

@MainActor
@Observable
final class ReaderModel {
    enum Phase { case booting, needsFolder, indexing, ready, failed(String) }

    private(set) var phase: Phase = .booting
    private(set) var entries: [Entry] = []
    /// The Mac's open tabs grouped by Space (each with its name/icon + forest of
    /// groups + nesting), resolved to local entries — the read-only "Mac 上打开的"
    /// sidebar. Published by the Mac into the synced folder; refreshed whenever
    /// entries change. Empty if the Mac never published.
    private(set) var openOnMacSpaces: [MacSpaceTabs] = []
    /// When the Mac last published its open tabs (from the snapshot's updatedAtMs).
    /// nil when no snapshot — drives the "同步于…" footer.
    private(set) var openTabsUpdatedAt: Date?
    /// Shared derived-state owner: holds the field-weighted searchIndex (rebuilt
    /// via scheduleDeferredDerivedRebuild after each entries update) plus counts,
    /// topicMembership, themeIndex, and relationGraph — same engine as the Mac.
    let catalog = Catalog()
    /// Progress during the indexing phase. nil = indeterminate (e.g. the build step).
    private(set) var progress: (done: Int, total: Int)?
    /// Human-readable status under the progress bar.
    private(set) var statusLabel: String = ""
    private var client: IOSVaultClient?
    private var workspaceRoot: String?
    /// The security-scoped URL we currently hold access to. Released before we
    /// acquire a new one so repeated picks/launches don't leak kernel handles.
    private var scopedURL: URL?

    /// App container path for the private index DB (never the synced vault).
    /// Computed once: the directory is created here at init.
    private let containerDBPath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarpleIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.sqlite").path
    }()

    /// Resolve a saved folder bookmark and boot; otherwise wait for a pick.
    /// A stale bookmark is re-saved inside `start` — creating bookmark data on
    /// iOS requires the security scope to be active, so doing it here would
    /// silently throw and the bookmark would never freshen (then eventually die).
    func boot() async {
        guard let (url, isStale) = VaultBookmark.resolve() else { phase = .needsFolder; return }
        await start(folder: url, resaveBookmark: isStale)
    }

    /// Called by the picker with a freshly chosen folder.
    func didPickFolder(_ url: URL) async {
        await start(folder: url, resaveBookmark: true)
    }

    private func start(folder url: URL, resaveBookmark: Bool = false) async {
        // Release any previously held scope before acquiring a new one (re-pick
        // or a second boot) — security-scoped handles are a limited per-process pool.
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        guard url.startAccessingSecurityScopedResource() else {
            phase = .failed("无法访问所选文件夹"); return
        }
        scopedURL = url
        let root = url.path
        // The workspace root must contain a `vault/` subdirectory (the app reads
        // <root>/vault/*.md). Picking the vault folder itself, or an unrelated
        // folder, lands here with a clear message instead of a silent empty library.
        var isDir: ObjCBool = false
        let vaultDir = url.appendingPathComponent("vault").path
        guard FileManager.default.fileExists(atPath: vaultDir, isDirectory: &isDir), isDir.boolValue else {
            phase = .failed("这个文件夹里没有 vault 子目录。\n请选择「包含 vault 的」文库根目录,而不是 vault 本身。")
            return
        }
        // Persist the bookmark only after access succeeds and the folder validates,
        // so we never save an unusable or wrong folder (and the bookmark is created
        // while the security scope is active, as iOS requires). Covers both a
        // fresh pick and freshening a stale bookmark from `boot`.
        if resaveBookmark { try? VaultBookmark.save(url) }
        workspaceRoot = root
        let dbPath = containerDBPath

        // Warm launch: an index already exists → show the library immediately from
        // it, then sync (download new + reconcile) in the background. This is what
        // makes a re-open instant instead of re-running the whole download/index
        // flow with the progress screen every time. `.ready` is set straight after
        // the SQLite read — the search-index rebuild and the session-file load
        // (which can block on an iCloud download for seconds) must NOT gate the
        // first paint (QUA-214).
        if FileManager.default.fileExists(atPath: dbPath) {
            let c = IOSVaultClient(workspaceRoot: root, db: IndexDatabase(indexDBPath: dbPath))
            if let warm = try? await c.index() {
                self.client = c
                self.entries = warm
                phase = .ready
                Task {
                    await self.finishEntriesUpdate(warm)
                    await self.backgroundSync(root: root, dbPath: dbPath)
                }
                return
            }
        }

        // Cold first run: no usable index yet → show progress while building.
        phase = .indexing
        progress = nil
        statusLabel = "正在准备…"
        do {
            await materializeMarkdown(under: root, report: true)
            progress = nil
            statusLabel = "正在建立索引…"
            try await Task.detached(priority: .utility) {
                _ = try VaultIndexer(workspaceRoot: root, indexDBPath: dbPath).buildFull()
            }.value
            let db = IndexDatabase(indexDBPath: dbPath)
            let c = IOSVaultClient(workspaceRoot: root, db: db)
            self.client = c
            // Cold start is sequential under phase==.indexing — no concurrent refresh can race here, so catalog.refresh (single-flight) isn't needed; the first index publishes directly.
            await updateEntries(try await c.index())
            phase = .ready
        } catch {
            phase = .failed("建立索引失败:\(error.localizedDescription)")
        }
    }

    /// Foreground refresh — runs the background sync, never blocking the UI or
    /// showing the progress screen.
    func refresh() async {
        guard case .ready = phase, let root = workspaceRoot else { return }
        await backgroundSync(root: root, dbPath: containerDBPath)
    }

    /// Download newly-synced `.md`, reconcile, and refresh entries — all in the
    /// background. Coalesced via Catalog's shared single-flight (RefreshAuthority):
    /// an overlapping launch/foreground sets a trailing rerun instead of being
    /// dropped, so the last signal always gets a fresh pass. Keeps `phase == .ready`.
    private func backgroundSync(root: String, dbPath: String) async {
        await catalog.refresh { [weak self] myPass in
            guard let self else { return }
            await self.materializeMarkdown(under: root, report: false)   // iOS-only iCloud download
            do {
                try await Task.detached(priority: .utility) {
                    _ = try VaultIndexer(workspaceRoot: root, indexDBPath: dbPath).reconcile()
                }.value
                if self.catalog.isStale(myPass) { return }               // newer pass started → drop this publish
                if let c = self.client { await self.updateEntries(try await c.index()) }
            } catch {
                print("[marple] background sync failed (keeping last entries): \(error)")
            }
        }
    }

    func text(for entry: Entry) async -> String {
        (try? await client?.entryText(path: entry.path)) ?? ""
    }

    /// Cross-type ranked search — the same field-weighted fuzzy ranker the Mac's
    /// 快速 command palette uses (`buildSearchIndex` + `searchDocuments`), run off
    /// the main actor so typing never hitches. Results are global; callers filter
    /// by type if they want a scoped list.
    func search(_ q: String) async -> [Entry] {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let index = catalog.searchIndex
        let ranked = await Task.detached(priority: .userInitiated) {
            searchDocuments(index, trimmed)
        }.value
        return ranked.map(\.entry)
    }

    /// Set entries and rebuild the search index (off-actor — thousands of docs).
    private func updateEntries(_ newEntries: [Entry]) async {
        self.entries = newEntries
        await finishEntriesUpdate(newEntries)
    }

    /// The non-urgent tail of an entries update: search-index rebuild + Mac
    /// session load. Split out so the warm-launch path can flip `.ready` first
    /// and run this in the background.
    private func finishEntriesUpdate(_ newEntries: [Entry]) async {
        // searchIndex is filled asynchronously by Catalog (scheduleDeferredDerivedRebuild,
        // fire-and-forget); search(_:) may return stale/empty for ~100–300ms after this
        // returns — matches the warm-launch behaviour (QUA-218 PR4 decision 2).
        // savedViews: [] — iOS has no saved views (recomputeSavedViewCounts early-returns).
        catalog.rebuildIndexDerived(entries: newEntries, savedViews: [])
        if let root = workspaceRoot { await loadSession(root: root) }
    }

    /// Read the Mac-published open-tabs file from the synced folder and resolve its
    /// per-Space forests into `MacSpaceTabs`, keeping Space names/icons + group
    /// names + nesting + the Mac's display label (custom name). Best-effort: a
    /// missing/未同步/legacy file yields an empty list (the sidebar group then
    /// hides). Unresolved docs, groups that end up empty, and Spaces whose forest
    /// resolves to empty are pruned.
    private func loadSession(root: String) async {
        let url = SessionFile.url(workspaceRoot: root)
        try? await ICloudMaterializer.ensureDownloaded(url)
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else {
            openOnMacSpaces = []
            openTabsUpdatedAt = nil
            return
        }
        openTabsUpdatedAt = Date(timeIntervalSince1970: Double(snap.updatedAtMs) / 1000)
        openOnMacSpaces = SessionResolver.resolve(snap, entries: entries)
    }

    /// Force-download the vault's `.md` files from iCloud, concurrently, in
    /// batches — far faster than serial for a multi-thousand-file vault. When
    /// `report` is true, drives the `progress`/`statusLabel` UI. Files iCloud
    /// hasn't surfaced yet aren't enumerated; the indexer skips any that still
    /// fail to read, and a later foreground `refresh()` picks them up.
    /// (Only `.md`; heavy media/PDFs stay evicted — v2.)
    private func materializeMarkdown(under root: String, report: Bool) async {
        let vault = URL(fileURLWithPath: root).appendingPathComponent("vault")
        let fm = FileManager.default
        var urls: [URL] = []
        if let en = fm.enumerator(at: vault, includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.pathExtension == "md" { urls.append(url) }
        }
        let total = urls.count
        if report {
            progress = (0, total)
            statusLabel = "正在从 iCloud 下载文库…"
        }
        guard total > 0 else { return }

        let batchSize = 12
        var done = 0
        var idx = 0
        while idx < urls.count {
            let batch = Array(urls[idx..<min(idx + batchSize, urls.count)])
            idx += batch.count
            // Download this batch concurrently; the group is a barrier (awaits all).
            // Tasks only capture a Sendable URL — no shared mutable state.
            await withTaskGroup(of: Void.self) { group in
                for url in batch {
                    group.addTask { try? await ICloudMaterializer.ensureDownloaded(url) }
                }
            }
            done += batch.count
            if report { progress = (done, total) }
        }
    }
}
