import SwiftUI
import MarpleKit

struct SidebarView: View {
    @Bindable var model: AppModel
    var body: some View {
        List(model.papers, selection: Binding(
            get: { model.openPath },
            set: { if let p = $0 { Task { await model.open(p) } } }
        )) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? "(untitled)").font(.headline).lineLimit(2)
                if let a = entry.author { Text(a).font(.caption).foregroundStyle(.secondary) }
            }
            .tag(entry.path)
        }
        .navigationTitle("论文 (\(model.papers.count))")
    }
}
