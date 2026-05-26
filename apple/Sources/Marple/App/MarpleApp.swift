import SwiftUI
import AppKit
import MarpleKit
import MarpleEmbeddings

final class AppState: ObservableObject {
    @Published var model: AppModel?
    @Published var booting = false
    @Published var bootError: String?
    private var indexer: VaultIndexer?
    private var watcher: VaultWatcher?

    @MainActor
    func boot(paths: VaultPaths) async {
        guard model == nil, !booting else { return }
        booting = true; bootError = nil
        let indexer = VaultIndexer(workspaceRoot: paths.workspaceRoot)
        self.indexer = indexer
        // Fast path: if the live index already exists and its schema is current,
        // skip awaiting reconcile. Open the existing SQLite, render the UI, and
        // run reconcile in the background — mirrors the FSEvents watcher below
        // and matches how Mail/Notes/NetNewsWire open instantly then refresh.
        // First launch / schema bump still awaits buildFull (the spinner stays
        // up because there's literally nothing to show yet).
        let canSkip = indexer.canSkipFullBuild()
        if !canSkip {
            do {
                _ = try await Task.detached { try indexer.reconcile() }.value
            } catch {
                print("[marple] boot reconcile failed (non-fatal): \(error)")
            }
        }
        let index = IndexDatabase(indexDBPath: paths.workspaceRoot + "/.marple/index.sqlite")
        let client = LocalVaultClient(workspaceRoot: paths.workspaceRoot, index: index)
        // 深度 (semantic) mode: wire the MLX backend only when a vector index exists
        // (built via `semantic-tool build`). Absent → AppModel keeps 深度 disabled.
        let marpleDir = URL(fileURLWithPath: paths.workspaceRoot).appendingPathComponent(".marple")
        let semantic: (any SemanticBackend)? =
            FileManager.default.fileExists(atPath: marpleDir.appendingPathComponent("vectors.json").path)
            ? MLXSemanticBackend(dir: marpleDir) : nil
        let m = AppModel(client: client, stateStore: UserDefaultsStateStore(), semantic: semantic)
        await m.loadIndex()
        self.model = m
        self.booting = false
        // If we took the fast path, the index we just showed may be stale. Run
        // reconcile on a background detached task, then re-load only when stats
        // show actual changes (skip the work for the typical no-edit restart).
        // Note: this task is fire-and-forget; the watcher is wired below before
        // this task runs. Concurrent reconciles (this one + watcher-triggered)
        // are safe — `VaultIndexer.writeLock` serialises the diff/write phase
        // on the live DB and SQLite WAL gives readers consistent snapshots, so
        // overlapping reconciles converge to the latest filesystem state.
        if canSkip {
            Task { @MainActor [weak m, indexer] in
                let stats: ReconcileStats?
                do { stats = try await Task.detached { try indexer.reconcile() }.value }
                catch {
                    print("[marple] deferred reconcile failed: \(error)")
                    stats = nil
                }
                if let s = stats, s.upserted + s.removed > 0 {
                    await m?.loadIndex()
                    await m?.reloadOpen()
                }
            }
        }
        // Wire the FSEvents watcher: on a debounced vault change, reconcile the
        // index then reload the list + open doc so external edits surface promptly.
        // Capture `indexer` directly (it is @unchecked Sendable) to avoid crossing
        // an actor boundary through `self` inside a @Sendable closure.
        let watcher = VaultWatcher(vaultDirectory: URL(fileURLWithPath: paths.vaultDir)) { [weak m, indexer] in
            // Reconcile off the main actor (synchronous/blocking).
            do { _ = try await Task.detached { try indexer.reconcile() }.value }
            catch { print("[marple] watcher reconcile failed: \(error)") }
            // Reload the list and the open document on the main actor.
            await m?.loadIndex()
            await m?.reloadOpen()
        }
        watcher.start()
        self.watcher = watcher
    }
}

@main
struct MarpleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer so logs stream to the captured file
        FontRegistration.registerBundledFonts()
    }

    // The main window is AppKit-owned (see MarpleWindowController) so the split view
    // can be the window's contentViewController. SwiftUI keeps only the Settings
    // scene and the menu commands.
    var body: some Scene {
        Settings { SettingsView() }
            .commands { TabCommands() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MarpleWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let wc = MarpleWindowController()
        windowController = wc
        wc.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
