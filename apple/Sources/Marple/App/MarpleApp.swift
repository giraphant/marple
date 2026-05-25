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
        // Run reconcile on a background thread so the main actor is never blocked.
        // On first run (no index) this performs a full build. Errors are logged but
        // do NOT crash the app — the list opens with whatever index already exists.
        do {
            _ = try await Task.detached { try indexer.reconcile() }.value
        } catch {
            print("[marple] boot reconcile failed (non-fatal): \(error)")
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
