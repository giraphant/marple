import SwiftUI
import AppKit
import MarpleKit

final class AppState: ObservableObject {
    @Published var model: AppModel?
    @Published var booting = false
    @Published var bootError: String?
    private var sidecar: SidecarProcess?
    private var watcher: VaultWatcher?

    @MainActor
    func boot(paths: VaultPaths) async {
        guard model == nil, !booting else { return }
        booting = true; bootError = nil
        let sidecar = SidecarProcess(repoRoot: paths.repoRoot, workspaceRoot: paths.workspaceRoot)
        self.sidecar = sidecar
        do {
            let base = try await sidecar.start()
            let client = HTTPVaultClient(baseURL: base)
            let m = AppModel(client: client, stateStore: UserDefaultsStateStore())
            await m.loadIndex()
            self.model = m
            self.booting = false
            let watcher = VaultWatcher(vaultDirectory: URL(fileURLWithPath: paths.vaultDir)) { [weak m] in
                await m?.reloadOpen()  // reloadOpen is @MainActor; await hops for us
            }
            watcher.start()
            self.watcher = watcher
        } catch {
            self.bootError = "\(error)"
            self.booting = false
        }
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

    /// Boot routing: no library picked → setup; library picked but the repo can't be
    /// located (binary moved out of the repo) → explain; otherwise boot.
    private enum BootContext {
        case needsLibrary
        case repoMissing(from: String)
        case ready(VaultPaths)
    }

    private var bootContext: BootContext {
        guard !workspaceRoot.isEmpty,
              let ws = try? resolveWorkspace(pickedPath: workspaceRoot) else {
            return .needsLibrary
        }
        guard let repo = findRepoRoot(startingFrom: Bundle.main.bundlePath) else {
            return .repoMissing(from: Bundle.main.bundlePath)
        }
        return .ready(VaultPaths(repoRoot: repo, workspaceRoot: ws.workspaceRoot, vaultDir: ws.vaultDir))
    }

    @ViewBuilder private var content: some View {
        switch bootContext {
        case .needsLibrary:
            SetupView { picked in workspaceRoot = picked }
        case .repoMissing(let from):
            ContentUnavailableView("找不到 marple 仓库", systemImage: "exclamationmark.triangle",
                                   description: Text("无法从\n\(from)\n向上找到 rust/Cargo.toml,请从仓库内运行。"))
        case .ready(let paths):
            if let model = state.model {
                RootView(model: model)
            } else if let err = state.bootError {
                ContentUnavailableView("启动失败", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else {
                ProgressView("启动 reader-api…")
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
