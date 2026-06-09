import Foundation
import SwiftUI
import MarpleKit

@MainActor
@Observable
final class ReaderModel {
    enum Phase { case needsFolder, indexing, ready, failed(String) }

    private(set) var phase: Phase = .needsFolder
    private(set) var entries: [Entry] = []
    private var client: IOSVaultClient?
    private var workspaceRoot: String?
    /// The security-scoped URL we currently hold access to. Released before we
    /// acquire a new one so repeated picks/launches don't leak kernel handles.
    private var scopedURL: URL?
    /// Guards against overlapping foreground refreshes (scene can flip
    /// .inactive→.active more than once in quick succession).
    private var refreshing = false

    /// App container path for the private index DB (never the synced vault).
    /// Computed once: the directory is created here at init.
    private let containerDBPath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarpleIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.sqlite").path
    }()

    /// Resolve a saved folder bookmark and boot; otherwise wait for a pick.
    func boot() async {
        guard let (url, isStale) = VaultBookmark.resolve() else { phase = .needsFolder; return }
        if isStale { try? VaultBookmark.save(url) }   // freshen the moved-file bookmark
        await start(folder: url)
    }

    /// Called by the picker with a freshly chosen folder.
    func didPickFolder(_ url: URL) async {
        await start(folder: url, freshPick: true)
    }

    private func start(folder url: URL, freshPick: Bool = false) async {
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
        // while the security scope is active, as iOS requires).
        if freshPick { try? VaultBookmark.save(url) }
        workspaceRoot = root
        phase = .indexing
        let dbPath = containerDBPath
        do {
            try await materializeMarkdown(under: root)
            try await Task.detached(priority: .utility) {
                let indexer = VaultIndexer(workspaceRoot: root, indexDBPath: dbPath)
                if indexer.canSkipFullBuild() { _ = try indexer.reconcile() }
                else { _ = try indexer.buildFull() }
            }.value
            let db = IndexDatabase(indexDBPath: dbPath)
            let c = IOSVaultClient(workspaceRoot: root, db: db)
            self.client = c
            self.entries = try await c.index()
            phase = .ready
        } catch {
            phase = .failed("建立索引失败:\(error.localizedDescription)")
        }
    }

    /// Re-index on foreground (cheap incremental reconcile).
    func refresh() async {
        guard !refreshing, let root = workspaceRoot, case .ready = phase else { return }
        refreshing = true
        defer { refreshing = false }
        let dbPath = containerDBPath
        do {
            try await materializeMarkdown(under: root)
            try await Task.detached(priority: .utility) {
                _ = try VaultIndexer(workspaceRoot: root, indexDBPath: dbPath).reconcile()
            }.value
            if let c = client { self.entries = try await c.index() }
        } catch {
            print("[marple] refresh failed (keeping last entries): \(error)")
        }
    }

    func text(for entry: Entry) async -> String {
        (try? await client?.entryText(path: entry.path)) ?? ""
    }

    func search(_ q: String) async -> [SearchHit] {
        (try? await client?.search(SearchQuery(q: q, limit: 80))) ?? []
    }

    /// Force-download only `.md` files (skip heavy media/PDFs).
    private func materializeMarkdown(under root: String) async throws {
        let vault = URL(fileURLWithPath: root).appendingPathComponent("vault")
        let fm = FileManager.default
        guard let en = fm.enumerator(at: vault, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en where url.pathExtension == "md" {
            try? await ICloudMaterializer.ensureDownloaded(url)
        }
    }
}
