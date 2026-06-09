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

    /// App container path for the private index DB (never the synced vault).
    private var containerDBPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarpleIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.sqlite").path
    }

    /// Resolve a saved folder bookmark and boot; otherwise wait for a pick.
    func boot() async {
        guard let url = VaultBookmark.resolve() else { phase = .needsFolder; return }
        await start(folder: url)
    }

    /// Called by the picker with a freshly chosen folder.
    func didPickFolder(_ url: URL) async {
        try? VaultBookmark.save(url)
        await start(folder: url)
    }

    private func start(folder url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            phase = .failed("无法访问所选文件夹"); return
        }
        let root = url.path
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
        guard let root = workspaceRoot, case .ready = phase else { return }
        let dbPath = containerDBPath
        do {
            try await materializeMarkdown(under: root)
            try await Task.detached(priority: .utility) {
                _ = try VaultIndexer(workspaceRoot: root, indexDBPath: dbPath).reconcile()
            }.value
            if let c = client { self.entries = try await c.index() }
        } catch { /* keep last good entries */ }
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
