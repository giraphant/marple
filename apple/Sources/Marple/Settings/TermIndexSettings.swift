import SwiftUI

struct TermIndexSettings: View {
    let controller: TermIndexController

    var body: some View {
        LabeledContent("状态") {
            if controller.isRunning {
                HStack { ProgressView().controlSize(.small); Text("正在更新术语索引") }
            } else {
                Text(controller.lastError != nil ? String(localized: "更新失败")
                    : controller.status == nil ? String(localized: "尚未建立") : String(localized: "就绪"))
            }
        }
        if let status = controller.status {
            LabeledContent("术语", value: status.terms.formatted())
            LabeledContent("对应关系", value: status.relations.formatted())
            LabeledContent("来源文档", value: status.sourceDocuments.formatted())
            LabeledContent("已扫描文档", value: status.scannedDocuments.formatted())
            LabeledContent("最近更新", value: status.updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
        if let error = controller.lastError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
        HStack {
            Button("刷新术语索引") { controller.scheduleRefresh() }
            Button("重建术语索引") {
                Task { try? await controller.refresh(rebuild: true) }
            }
        }
        .disabled(controller.isRunning)
        Text("从文库术语表提取中英文对应关系。文档变化后自动更新；重建失败时保留原有索引。")
            .font(.caption).foregroundStyle(.secondary)
    }
}
