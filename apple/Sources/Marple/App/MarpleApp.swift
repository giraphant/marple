import SwiftUI
import AppKit
import MarpleKit
import MarpleEmbeddings

/// App-level services for the open vault: the shared `Library` plus the indexer,
/// watcher, CLI socket and backups. Started once; windows come and go on top.
@MainActor
final class AppState: ObservableObject {
    @Published var library: Library?
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

    /// Opens a window when one is needed and none exists (CLI / URL requests).
    var windowProvider: (() -> AppModel?)?

    /// Synchronous (no awaits inside) since Phase A — the heavy reconcile +
    /// loadIndex moved to a background Task at the bottom of this method. Lets
    /// the first window mount the split chrome BEFORE it is ordered front,
    /// eliminating the brief "blank window" flash that an async boot would leave
    /// between `showWindow` and the split mount.
    func boot(paths: VaultPaths) {
        guard library == nil, !booting else { return }
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
        let m = Library(client: client, stateStore: UserDefaultsStateStore(),
                        semantic: semantic, isFirstRun: !canSkip,
                        workspaceRoot: paths.workspaceRoot)
        self.library = m
        m.cliIndexer = indexer
        m.termIndexController = TermIndexController(workspaceRoot: paths.workspaceRoot)
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
                catch {
                    m?.recordIndexFailure(error, context: String(localized: "启动时建立索引失败"))
                    print("[marple] boot reconcile failed (non-fatal): \(error)")
                }
            }
            await m?.loadIndex()
            m?.termIndexController?.scheduleRefresh()
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
                            m.recordIndexFailure(error, context: String(localized: "后台更新索引失败"))
                            print("[marple] deferred reconcile failed: \(error)")
                            stats = nil
                        }
                        if let s = stats, s.upserted + s.removed > 0 {
                            await m.loadIndex(pass: myPass)
                            await m.reloadOpenDocuments()
                        }
                        m.endRefreshing()
                    }
                }
            }
        }
    }

    private func applyCLISetting() {
        guard let cliServer, library != nil, let indexer else { return }
        let wanted = UserDefaults.standard.bool(forKey: SettingsKeys.cliServerEnabled)
        if wanted {
            do {
                try cliServer.start(model: { [weak self] in self?.windowProvider?() }, indexer: indexer)
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
    /// SwiftUI owns the real `NSApp.delegate` (adaptor), so menu commands reach
    /// this one through here.
    private(set) static weak var shared: AppDelegate?
    private let appState = AppState()
    private let memoryPressureMonitor = MemoryPressureMonitor()
    private let memoryWatchdog = MemoryWatchdog()
    /// Set once quitting starts: windows AppKit closes from here on are not
    /// "closed by the user" and stay in the saved session.
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        appState.windowProvider = { [weak self] in self?.frontModelOpeningIfNeeded() }
        route()
        memoryPressureMonitor.start()
        memoryWatchdog.start()
    }

    /// Pick the vault (first run) or boot it and reopen the saved windows.
    private func route() {
        let root = UserDefaults.standard.string(forKey: "marple.workspaceRoot") ?? ""
        guard !root.isEmpty, let ws = try? resolveWorkspace(pickedPath: root) else {
            let controller = ActiveModel.controllers.first ?? makeController()
            controller.showSetup { [weak self] picked in
                UserDefaults.standard.set(picked, forKey: "marple.workspaceRoot")
                self?.route()
            }
            return
        }
        // QUA-105: `AppState.boot` is synchronous (the data load runs on a
        // background Task), so windows mount their split chrome immediately and
        // render skeleton state until the first loadIndex completes.
        appState.boot(paths: VaultPaths(workspaceRoot: ws.workspaceRoot, vaultDir: ws.vaultDir))
        guard let library = appState.library else {
            let controller = ActiveModel.controllers.first ?? makeController()
            controller.showBootError(appState.bootError ?? "")
            return
        }
        library.frontToBack = { models in
            let order = ActiveModel.orderedControllers.compactMap(\.model)
            return order.filter { model in models.contains { $0 === model } }
        }
        library.openWindow = { [weak self] source in self?.openWindow(cloning: source) }
        var restored: [RestoredWindow?] = []
        while let window = library.takeRestoredWindow() { restored.append(window) }
        if restored.isEmpty { restored = [nil] }   // first launch: one fresh window
        // A setup window (first run) becomes the first main window.
        let setup = ActiveModel.controllers.first { $0.model == nil }
        // Back to front, so the saved front window ends up in front.
        for (index, window) in restored.enumerated().reversed() {
            let model = AppModel(library: library, restoring: window)
            let controller = index == 0 ? (setup ?? makeController()) : makeController()
            controller.show(model, cascadeFrom: nil)
        }
    }

    private func makeController() -> MarpleWindowController {
        let controller = MarpleWindowController()
        controller.onClose = { [weak self] closed in self?.windowDidClose(closed) }
        ActiveModel.controllers.append(controller)
        return controller
    }

    /// A new main window. `source` (the window it was opened from) gives its Space,
    /// browse controls and folder collapse; nil reopens the last closed window
    /// when there is one, else a fresh window.
    @discardableResult
    func openWindow(cloning source: AppModel?) -> AppModel? {
        guard let library = appState.library else { return nil }
        let restoring = source?.newWindowState() ?? library.takeRecentlyClosedWindow()
        let model = AppModel(library: library, restoring: restoring)
        let sourceWindow = source.flatMap { model in
            ActiveModel.controllers.first { $0.model === model }?.window
        }
        makeController().show(model, cascadeFrom: sourceWindow)
        return model
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(cloning: ActiveModel.current)
    }

    @objc private func newNote(_ sender: Any?) {
        guard let model = frontModelOpeningIfNeeded() else { return }
        Task { await model.newIdeaNote() }
    }

    /// Dock menu: the app's own actions. AppKit lists the open windows above them
    /// by title (see `AppModel.windowTitle`).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard appState.library != nil else { return nil }
        let menu = NSMenu()
        for (title, action) in [(String(localized: "新建窗口"), #selector(newWindow(_:))),
                                (String(localized: "新建笔记"), #selector(newNote(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func frontModelOpeningIfNeeded() -> AppModel? {
        ActiveModel.current ?? openWindow(cloning: nil)
    }

    private func windowDidClose(_ controller: MarpleWindowController) {
        ActiveModel.controllers.removeAll { $0 === controller }
        guard let model = controller.model, let library = appState.library else { return }
        if isTerminating { return }
        library.windowDidClose(model)
    }

    /// Closing the last window keeps Marple (and its services) running; the Dock
    /// icon or 新建窗口 brings a window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        guard appState.library != nil else {
            // The setup window was closed before a vault was chosen.
            if ActiveModel.controllers.isEmpty { route() }
            return false
        }
        if let controller = ActiveModel.orderedControllers.first {
            controller.window?.makeKeyAndOrderFront(nil)   // minimized / hidden
        } else {
            openWindow(cloning: nil)
        }
        return false
    }

    /// Inline-note edits are staged in memory while typing (issue #87) and
    /// normally flushed on blur/doc-switch; quitting mid-edit must not lose them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        appState.library?.persist()
        guard let notes = appState.library?.notes, notes.hasDirty else {
            return .terminateNow
        }
        Task { @MainActor in
            await notes.flushAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// QUA-107: cold-start handler for marple:// URLs. The primary IPC path is
    /// the Unix socket served by CLIServer; this URL scheme exists so
    /// `marple-cli open <path>` can launch Marple and open a document page.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { @MainActor in await self.handle(url: url) }
        }
    }

    private func handle(url: URL) async {
        // Cold-start race: the URL can arrive before the library is ready.
        // Poll briefly (≤ 5s) and bail rather than queue indefinitely.
        let deadline = Date().addingTimeInterval(5.0)
        while appState.library == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let model = frontModelOpeningIfNeeded() else { return }

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
