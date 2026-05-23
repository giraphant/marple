import SwiftUI
import AppKit
import MarpleKit

/// First-run: pick the library (workspace) folder. Validates it contains a `vault/`
/// (or is one) and hands the path up to be persisted + booted. The code repo is
/// auto-derived from the running binary, so it isn't asked for here.
struct SetupView: View {
    var onPicked: (String) -> Void
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical").font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("选择文库").font(.title2.weight(.semibold))
            Text("选择包含 vault/ 的文库工作区目录。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("选择文库目录…") { pick() }.controlSize(.large).keyboardShortcut(.defaultAction)
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
            _ = try resolveWorkspace(pickedPath: url.path)
            error = nil
            onPicked(url.path)
        } catch {
            self.error = "该目录里没有 vault/ 文件夹,请选择你的文库工作区目录。"
        }
    }
}
