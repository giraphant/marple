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
    // QUA-106: periodic local snapshot backups. Constructed during boot,
    // started/stopped by `applyBackupSetting` per `marple.backupEnabled`.
    private var backupScheduler: BackupScheduler?
    private var backupWatcher: VaultWatcher?
    private var semanticIndexController: SemanticIndexRefreshController?

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
        // 深度 (semantic) mode: wire the MLX backend only when both the vector
        // index and MLX Metal kernels are present. Missing kernels hard-crash MLX
        // below Swift's do/catch, so fail closed and let the palette disable 深度.
        let marpleDir = URL(fileURLWithPath: paths.workspaceRoot).appendingPathComponent(".marple")
        let semanticRuntimeAvailable = Self.semanticRuntimeAvailable()
        let semanticIndexAvailable = Self.semanticIndexAvailable(marpleDir: marpleDir)
        let semantic: (any SemanticBackend)? = semanticRuntimeAvailable && semanticIndexAvailable
            ? MLXSemanticBackend(dir: marpleDir) : nil
        let m = AppModel(client: client, stateStore: UserDefaultsStateStore(),
                         semantic: semantic, isFirstRun: !canSkip,
                         workspaceRoot: paths.workspaceRoot)
        self.model = m
        m.cliIndexer = indexer
        if semanticRuntimeAvailable {
            let semanticIndexController = SemanticIndexRefreshController(
                workspaceRoot: paths.workspaceRoot,
                marpleDir: marpleDir)
            self.semanticIndexController = semanticIndexController
            ActiveSemanticIndex.controller = semanticIndexController
        } else {
            self.semanticIndexController = nil
            ActiveSemanticIndex.controller = nil
        }
        self.booting = false

        // Wire the FSEvents watcher and CLI server up front — they're safe to
        // exist before the first loadIndex completes. The watcher's onChange
        // routes through `catalog.refresh`, and the per-pass generation guard in
        // AppModel.loadIndex makes overlapping bootstrap + watcher-triggered
        // calls converge to the latest snapshot.
        // QUA-198: the Coalescer debounces signals but does NOT bound concurrency
        // — once a debounced action fires, the next signal can fire another while
        // the first is still mid-reconcile. During a vault write storm these
        // chains piled up unboundedly (each holding a full [Entry] SQL read).
        // `catalog.refresh` admits one chain at a time (RefreshAuthority single-
        // flight); signals arriving mid-run collapse into a single trailing rerun
        // so no change is missed.
        // QUA-212/QUA-218: the single-flight authority lives on Catalog so the CLI
        // surface joins the same flight (via refreshJoining) instead of running an
        // ungated duplicate reconcile.
        let watcher = VaultWatcher(vaultDirectory: URL(fileURLWithPath: paths.vaultDir))
        watcher.start { [weak m] in
            guard let m else { return }
            Task { await m.catalog.refresh(m.refreshBody) }
        }
        self.watcher = watcher

        // QUA-106: backup engine. The store walks the whole workspaceRoot for
        // change detection, so it's wired independently of the index/watcher.
        // The backup root lives OUTSIDE the vault (no snapshot-of-snapshots).
        let store = SnapshotStore(
            workspaceRoot: URL(fileURLWithPath: paths.workspaceRoot),
            backupsBase: BackupScheduler.resolveBase())
        let scheduler = BackupScheduler(store: store)
        self.backupScheduler = scheduler
        ActiveBackup.scheduler = scheduler
        self.backupWatcher = VaultWatcher(vaultDirectory: URL(fileURLWithPath: paths.workspaceRoot))
        applyBackupSetting()

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
                Task { @MainActor in
                    self?.applyCLISetting()
                    self?.applyBackupSetting()
                }
            }
            if canSkip {
                Task { @MainActor [weak m, indexer] in
                    guard let m else { return }
                    // QUA-212/QUA-218: go through `catalog.refresh` so a CLI search
                    // arriving mid-boot joins this single flight instead of stacking
                    // a duplicate walk. refresh internally does tryBegin (busy →
                    // the active runner's trailing rerun covers this) + the
                    // finishOrRerun loop. The body keeps the stats-conditional
                    // reload: only re-load the index when the deferred reconcile
                    // actually found stale rows (the boot loadIndex above already
                    // published the cached snapshot).
                    await m.catalog.refresh { [weak m, indexer] myPass in
                        guard let m else { return }
                        m.beginRefreshing()
                        let stats: ReconcileStats?
                        do { stats = try await Task.detached { try indexer.reconcile() }.value }
                        catch {
                            print("[marple] deferred reconcile failed: \(error)")
                            stats = nil
                        }
                        if let s = stats, s.upserted + s.removed > 0 {
                            await m.loadIndex(pass: myPass)
                            await m.reloadOpen()
                        }
                        m.endRefreshing()
                    }
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

    private static func semanticRuntimeAvailable() -> Bool {
        let fm = FileManager.default
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent(),
           fm.fileExists(atPath: exeDir.appendingPathComponent("mlx.metallib").path) {
            return true
        }
        if fm.fileExists(atPath: FileManager.default.currentDirectoryPath + "/default.metallib") {
            return true
        }

        print("[marple] semantic disabled: missing MLX metallib")
        return false
    }

    private static func semanticIndexAvailable(marpleDir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: marpleDir.appendingPathComponent("vectors.json").path)
            && fm.fileExists(atPath: marpleDir.appendingPathComponent("vectors.f32").path)
    }

    /// Start/stop the backup scheduler per `marple.backupEnabled` (default true
    /// when the key was never set — it's a safety feature, on by default).
    private func applyBackupSetting() {
        guard let backupScheduler else { return }
        let defaults = UserDefaults.standard
        let wanted = defaults.object(forKey: SettingsKeys.backupEnabled) as? Bool ?? true
        if wanted {
            backupWatcher?.start { [weak backupScheduler] in backupScheduler?.noteVaultChanged() }
            backupScheduler.start()
        } else {
            backupWatcher?.stop()
            backupScheduler.stop()
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
        // Persist stdout/stderr to ~/Library/Logs/Marple/marple.log (also sets
        // line buffering). A Finder-launched .app otherwise drops print() to
        // /dev/null, leaving no trail when something runs away (e.g. the 48 GB
        // memory blow-up during a Terminal book-creation storm).
        MarpleLog.redirectToFile()
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
    private let memoryPressureMonitor = MemoryPressureMonitor()
    private let memoryWatchdog = MemoryWatchdog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let wc = MarpleWindowController()
        windowController = wc
        wc.start()
        memoryPressureMonitor.start()
        memoryWatchdog.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Inline-note edits are staged in memory while typing (issue #87) and
    /// normally flushed on blur/doc-switch; quitting mid-edit must not lose them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = ActiveModel.current, model.hasDirtyInspectorNotes else {
            return .terminateNow
        }
        Task { @MainActor in
            await model.flushAllInspectorNoteSaves()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

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
