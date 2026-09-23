import SwiftUI
import MarpleKit

/// Only navigation within a collection; collections themselves are browse rows.
struct ArchiveCollectionsView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let group = model.archiveCollections.first(where: { $0.path == model.archiveCollectionPath }) {
                HStack {
                    Button { model.select(pane: .type(.archive)); model.archiveCollectionPath = nil } label: { Label("档案", systemImage: "chevron.left") }
                    Text(group.title).lineLimit(1)
                    Spacer()
                    Text("\(group.members.count) 个档案").foregroundStyle(.secondary)
                }.padding(8)
            }
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
