import SwiftUI
import MarpleKit

struct DocView: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if model.openPath == nil {
                ContentUnavailableView("选择一篇论文", systemImage: "doc.text")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.openBlocks.enumerated()), id: \.offset) { _, block in
                            BlockView(block: block) { target in
                                Task { await model.follow(target) }
                            }
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("用外部编辑器打开") { Task { await model.openExternally() } }
                    .disabled(model.openPath == nil)
            }
        }
    }
}
