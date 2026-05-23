import SwiftUI
import AppKit
import MarpleKit

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
        let m = AppModel(client: client, stateStore: UserDefaultsStateStore())
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
    @StateObject private var state = AppState()
    @AppStorage("marple.workspaceRoot") private var workspaceRoot = ""

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer so logs stream to the captured file
    }

    var body: some Scene {
        WindowGroup {
            content.frame(minWidth: 900, minHeight: 600)
        }
        .commands { TabCommands() }
    }

    /// Boot routing: no library picked → setup; library picked → boot with VaultIndexer.
    private enum BootContext {
        case needsLibrary
        case ready(VaultPaths)
    }

    private var bootContext: BootContext {
        guard !workspaceRoot.isEmpty,
              let ws = try? resolveWorkspace(pickedPath: workspaceRoot) else {
            return .needsLibrary
        }
        return .ready(VaultPaths(workspaceRoot: ws.workspaceRoot, vaultDir: ws.vaultDir))
    }

    @ViewBuilder private var content: some View {
        switch bootContext {
        case .needsLibrary:
            SetupView { picked in workspaceRoot = picked }
        case .ready(let paths):
            if let model = state.model {
                RootView(model: model)
            } else if let err = state.bootError {
                ContentUnavailableView("启动失败", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else {
                ProgressView("建立索引…")
                    .padding()
                    .task { await state.boot(paths: paths) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running a SwiftUI app from `swift run` needs an explicit activation
        // policy + activate so the window comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
