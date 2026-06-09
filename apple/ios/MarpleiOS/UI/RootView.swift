import SwiftUI

struct RootView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        switch model.phase {
        case .needsFolder:
            SetupView { url in Task { await model.didPickFolder(url) } }
        case .indexing:
            VStack(spacing: 12) { ProgressView(); Text("正在建立索引…").foregroundStyle(.secondary) }
        case .failed(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg).multilineTextAlignment(.center).padding()
                Button("重新选择文件夹") { Task { VaultBookmark.clear(); await model.boot() } }
            }
        case .ready:
            NavigationStack { SidebarScreen(model: model) }
        }
    }
}
