import SwiftUI
import MarpleKit

/// Collection operation feedback and rename prompt.
struct ArchiveCollectionsView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.archiveCollectionError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button { model.archiveCollectionError = nil } label: { Image(systemName: "xmark") }
                }.padding(8)
            }
        }
        .buttonStyle(.borderless)
        .alert("重命名合集", isPresented: Binding(get: { model.archiveCollectionRenamePath != nil }, set: { if !$0 { model.archiveCollectionRenamePath = nil } })) {
            TextField("名称", text: $model.archiveCollectionRenameName)
            Button("取消", role: .cancel) { model.archiveCollectionRenamePath = nil }
            Button("保存") {
                guard let path = model.archiveCollectionRenamePath else { return }
                let name = model.archiveCollectionRenameName
                model.archiveCollectionRenamePath = nil
                Task {
                    do { _ = try await model.performArchiveCollection(.init(action: "rename", paths: [path], name: name)) }
                    catch { model.archiveCollectionError = String(describing: error) }
                }
            }
        }
    }
}
