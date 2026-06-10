import SwiftUI

struct RootView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        switch model.phase {
        case .booting:
            // Resolving the saved bookmark — never flash the folder picker here,
            // or every launch looks like the vault pick was lost (QUA-214).
            ProgressView()
        case .needsFolder:
            SetupView { url in Task { await model.didPickFolder(url) } }
        case .indexing:
            VStack(spacing: 14) {
                if let p = model.progress, p.total > 0 {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 240)
                    Text("\(model.statusLabel) \(p.done)/\(p.total)")
                        .font(.callout).foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                    Text(model.statusLabel.isEmpty ? "正在建立索引…" : model.statusLabel)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding()
        case .failed(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg).multilineTextAlignment(.center).padding()
                // Transient failures (file provider not ready yet) recover on
                // retry — don't force a re-pick by clearing the bookmark.
                Button("重试") { Task { await model.boot() } }
                    .buttonStyle(.borderedProminent)
                Button("重新选择文件夹") { Task { VaultBookmark.clear(); await model.boot() } }
            }
        case .ready:
            NavigationStack { SidebarScreen(model: model) }
        }
    }
}
