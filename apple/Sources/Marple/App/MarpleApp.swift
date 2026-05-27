import SwiftUI
import AppKit
import MarpleKit
import MarpleEmbeddings

@MainActor
final class AppState: ObservableObject {
    @Published var model: AppModel?
    @Published var booting = false
    @Published var bootError: String?
    private var indexer: VaultIndexer?
    private var watcher: VaultWatcher?
    // QUA-107: local CLI socket. Lifetime gated by the "允许 CLI 接入" setting;
    // see `applyCLISetting` for the toggle path.
    private var cliServer: CLIServer?
    private var cliSettingObserver: NSObjectProtocol?

    /// Synchronous (no awaits inside) since Phase A — the heavy reconcile +
    /// loadIndex moved to a background Task at the bottom of this method. Lets
    /// `MarpleWindowController.start()` mount the split chrome BEFORE the
    /// window is ordered front, eliminating the brief "blank window" flash
    /// that an async boot would leave between `showWindow` and the split mount.
    func boot(paths: VaultPaths) {
        guard model == nil, !booting else { return }
        booting = true; bootError = nil
        let indexer = VaultIndexer(workspaceRoot: paths.workspaceRoot)
        self.indexer = indexer
        // QUA-105: publish the model BEFORE running reconcile / loadIndex.
        // Previously both ran behind `await` so the window sat on a spinner
        // for several seconds on first launch (slow path) and flashed
        // "spinner → split swap" on every warm launch. Now the window mounts
        // the split chrome at t≈0 with `isBootstrapping=true`, and the data
        // path runs as a background Task that flips bootstrap when the first
        // snapshot lands. Mirrors how Mail/Notes/NetNewsWire feel instant.
        let canSkip = indexer.canSkipFullBuild()
        let index = IndexDatabase(indexDBPath: paths.workspaceRoot + "/.marple/index.sqlite")
        let client = LocalVaultClient(workspaceRoot: paths.workspaceRoot, index: index)
        // 深度 (semantic) mode: wire the MLX backend only when a vector index exists
        // (built via `semantic-tool build`). Absent → AppModel keeps 深度 disabled.
        let marpleDir = URL(fileURLWithPath: paths.workspaceRoot).appendingPathComponent(".marple")
        let semantic: (any SemanticBackend)? =
            FileManager.default.fileExists(atPath: marpleDir.appendingPathComponent("vectors.json").path)
            ? MLXSemanticBackend(dir: marpleDir) : nil
        let m = AppModel(client: client, stateStore: UserDefaultsStateStore(), semantic: semantic)
        self.model = m
        self.booting = false

        // Wire the FSEvents watcher and CLI server up front — they're safe to
        // exist before the first loadIndex completes. The watcher's reconcile
        // closure calls loadIndex itself, and the generation guard in
        // AppModel.loadIndex makes overlapping bootstrap + watcher-triggered
        // calls converge to the latest snapshot.
        let watcher = VaultWatcher(vaultDirectory: URL(fileURLWithPath: paths.vaultDir)) { [weak m, indexer] in
            await m?.beginRefreshing()
            do { _ = try await Task.detached { try indexer.reconcile() }.value }
            catch { print("[marple] watcher reconcile failed: \(error)") }
            await m?.loadIndex()
            await m?.reloadOpen()
            await m?.endRefreshing()
        }
        watcher.start()
        self.watcher = watcher

        // QUA-107: construct the CLI socket holder now, but defer the actual
        // listen + UserDefaults observer until the first loadIndex publishes
        // (see the post-loadIndex tail below). Before that, AppModel.entries
        // is empty, so handlers like `open` / `read` would return spurious
        // "entry not found" instead of the connection-refused signal CLI
        // clients used to see — which they retry against. Same end behavior
        // as pre-QUA-105 (CLIServer wiring was after loadIndex).
        self.cliServer = CLIServer()

        // Kick the actual data load on a background task. Sequence:
        //  · slow path (canSkip=false, first launch / schema bump): reconcile,
        //    then loadIndex publishes the freshly built snapshot.
        //  · fast path (canSkip=true): loadIndex now against the cached
        //    sidecar, then a second reconcile catches any stale rows and
        //    re-loads only if it found real changes. Unchanged behavior — just
        //    no longer blocking the UI mount.
        Task { @MainActor [weak self, weak m, indexer] in
            if !canSkip {
                do { _ = try await Task.detached { try indexer.reconcile() }.value }
                catch { print("[marple] boot reconcile failed (non-fatal): \(error)") }
            }
            await m?.loadIndex()
            // Now safe to expose the CLI surface — entries is published.
            self?.applyCLISetting()
            self?.cliSettingObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applyCLISetting() }
            }
            if canSkip {
                Task { @MainActor [weak m, indexer] in
                    m?.beginRefreshing()
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
                    m?.endRefreshing()
                }
            }
        }
    }

    private func applyCLISetting() {
        guard let cliServer, let model, let indexer else { return }
        let wanted = UserDefaults.standard.bool(forKey: SettingsKeys.cliServerEnabled)
        if wanted {
            do {
                try cliServer.start(model: model, indexer: indexer)
            } catch {
                print("[marple] CLI server start failed: \(error)")
            }
        } else {
            cliServer.stop()
        }
    }

    func shutdownCLIBridge() {
        if let o = cliSettingObserver {
            NotificationCenter.default.removeObserver(o)
            cliSettingObserver = nil
        }
        cliServer?.stop()
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

    /// QUA-107: cold-start handler for marple:// URLs. The primary IPC path is
    /// the Unix socket served by CLIServer; this URL scheme exists so
    /// `marple-cli open <path>` can launch Marple and open a document page.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { @MainActor in await Self.handle(url: url) }
        }
    }

    private static func handle(url: URL) async {
        // Cold-start race: the URL can arrive before AppModel is ready.
        // Poll briefly (≤ 5s) and bail rather than queue indefinitely.
        let deadline = Date().addingTimeInterval(5.0)
        while ActiveModel.current == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let model = ActiveModel.current else { return }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = url.host(percentEncoded: false) ?? ""
        let items = comps?.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            item.value.map { (item.name, $0) }
        })

        switch host {
        case "open":
            if let path = params["path"], !path.isEmpty {
                try? await model.cliOpenDocument(path: path)
            }
        default:
            print("[marple] ignored marple:// host: \(host)")
        }
    }
}
