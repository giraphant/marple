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
        .alert(model.archiveCollectionAssignPaths == nil ? String(localized: "重命名合集") : String(localized: "设置合集"), isPresented: Binding(get: { model.archiveCollectionRenamePath != nil || model.archiveCollectionAssignPaths != nil }, set: { if !$0 { model.archiveCollectionRenamePath = nil; model.archiveCollectionAssignPaths = nil } })) {
            TextField("名称", text: $model.archiveCollectionRenameName)
            Button("取消", role: .cancel) { model.archiveCollectionRenamePath = nil; model.archiveCollectionAssignPaths = nil }
            Button("保存") {
                let paths = model.archiveCollectionAssignPaths ?? model.archiveCollectionRenamePath.map { [$0] } ?? []
                let action = model.archiveCollectionAssignPaths == nil ? "rename" : "assign"
                let name = model.archiveCollectionRenameName
                model.archiveCollectionRenamePath = nil
                model.archiveCollectionAssignPaths = nil
                Task {
                    do { _ = try await model.performArchiveCollection(.init(action: action, paths: paths, name: name)) }
                    catch { model.archiveCollectionError = String(describing: error) }
                }
            }.disabled(model.archiveCollectionRenameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
