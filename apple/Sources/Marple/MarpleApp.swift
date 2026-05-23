import SwiftUI
import AppKit
import MarpleKit

final class AppState: ObservableObject {
    let sidecar: SidecarProcess
    @Published var model: AppModel?
    @Published var booting = true
    @Published var bootError: String?
    private var watcher: VaultWatcher?

    init(repoRoot: String) {
        self.sidecar = SidecarProcess(repoRoot: repoRoot)
    }

    @MainActor
    func boot(repoRoot: String, vaultDir: URL) async {
        do {
            let base = try await sidecar.start()
            let client = HTTPVaultClient(baseURL: base)
            let m = AppModel(client: client)
            await m.loadIndex()
            self.model = m
            self.booting = false
            let watcher = VaultWatcher(vaultDirectory: vaultDir) { [weak m] in
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
    @StateObject private var state: AppState

    // P1 dev config: this repo holds rust/ and marple.config.json; the vault is
    // resolved by reader-api from marple.config.json's workspaceRoot.
    static let repoRoot = "/Users/ramudai/Documents/Learn/marple"
    static let vaultDir = URL(fileURLWithPath: "/Users/ramudai/Documents/Learn/bts/vault")

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer so logs stream to the captured file
        _state = StateObject(wrappedValue: AppState(repoRoot: MarpleApp.repoRoot))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = state.model {
                    NavigationSplitView {
                        SidebarView(model: model).frame(minWidth: 260)
                    } detail: {
                        DocView(model: model)
                    }
                } else if state.booting {
                    ProgressView("启动 reader-api…").padding()
                } else {
                    ContentUnavailableView("启动失败", systemImage: "exclamationmark.triangle",
                                           description: Text(state.bootError ?? "unknown"))
                }
            }
            .task {
                await state.boot(repoRoot: MarpleApp.repoRoot, vaultDir: MarpleApp.vaultDir)
            }
            .frame(minWidth: 900, minHeight: 600)
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
