import Foundation
import MarpleKit
import Observation

@Observable @MainActor
final class AppModel {
    let client: VaultClient
    var entries: [Entry] = []
    var openPath: String?
    var openBlocks: [RenderBlock] = []
    var status: String = ""

    init(client: VaultClient) { self.client = client }

    var papers: [Entry] {
        entries.filter { $0.type == .paperAnalysis }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    func loadIndex() async {
        do {
            entries = try await client.index()
            status = "\(entries.count) entries"
            print("[marple] index loaded: \(entries.count) entries, \(papers.count) papers")
        } catch {
            status = "index failed: \(error)"
            print("[marple] index FAILED: \(error)")
        }
    }

    func open(_ path: String) async {
        openPath = path
        do {
            let raw = try await client.entryText(path: path)
            openBlocks = MarkdownModel.blocks(from: Frontmatter.split(raw).body)
            print("[marple] open \(path) -> \(openBlocks.count) blocks (\(raw.count) chars)")
        } catch {
            openBlocks = [.paragraph([.text("load failed: \(error)")])]
            print("[marple] open FAILED \(path): \(error)")
        }
    }

    func reloadOpen() async {
        if let p = openPath { print("[marple] watcher reload \(p)"); await open(p) }
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
}
