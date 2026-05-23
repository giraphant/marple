import SwiftUI
import AppKit
import MarpleKit

/// Shown when no valid repo root is configured. Picks a folder, validates it has a
/// readable marple.config.json, and hands the path up to be persisted + booted.
struct SetupView: View {
    var onPicked: (String) -> Void
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.gearshape").font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("选择 marple 仓库目录").font(.title2.weight(.semibold))
            Text("需要包含 marple.config.json 和 rust/ 的目录。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("选择目录…") { pick() }.controlSize(.large).keyboardShortcut(.defaultAction)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try resolveVaultPaths(repoRoot: url.path)
            error = nil
            onPicked(url.path)
        } catch let e as VaultPathsError {
            switch e {
            case .missingConfig: error = "该目录缺少 marple.config.json,请选择 marple 仓库根目录。"
            case .badConfig(let m): error = "无法读取配置:\(m)"
            }
        } catch {
            self.error = "\(error)"
        }
    }
}
