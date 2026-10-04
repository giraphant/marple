import SwiftUI
import MarpleKit

struct ArchiveGroupingMenu: View {
    let model: AppModel

    var body: some View {
        if model.pane == .type(.archive), !model.isPinnedListContext {
            Menu {
                Picker("分组依据", selection: Binding(get: { model.archiveGrouping ?? "" }, set: {
                    model.archiveGrouping = $0.isEmpty ? nil : $0
                })) {
                    Text("不分组").tag("")
                    ForEach(model.archiveGroupingFields, id: \.self) { field in
                        Text(field).tag(field)
                    }
                }
                if model.archiveGrouping != nil {
                    Divider()
                    Button("展开所有分组") { model.expandedArchiveCollections = Set(model.archiveBrowseGroups.map(\.id)) }
                    Button("收起所有分组") { model.expandedArchiveCollections.removeAll() }
                }
            } label: {
                Image(systemName: model.archiveGrouping == nil ? "square.3.layers.3d" : "square.3.layers.3d.top.filled")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "分组依据"))
            .accessibilityLabel(String(localized: "分组依据"))
        }
    }
}
