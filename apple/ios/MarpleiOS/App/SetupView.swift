import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    let onPick: (URL) -> Void
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("选择已同步的文库文件夹").font(.headline)
            Text("通过 iCloud Drive 同步过来的 Marple 文库根目录").font(.subheadline).foregroundStyle(.secondary)
            Button("选择文件夹…") { showPicker = true }.buttonStyle(.borderedProminent)
        }
        .padding()
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { onPick(url) }
        }
    }
}
