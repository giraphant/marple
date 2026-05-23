import SwiftUI
import MarpleKit

/// The booted app shell: a tab strip over the three-column browse/read split.
/// Publishes the model as a scene-focused value so the 标签 menu commands reach it.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabStripView(model: model)
            Divider()
            NavigationSplitView {
                SidebarView(model: model).frame(minWidth: 220)
            } content: {
                Group {
                    switch model.pane {
                    case .themesIndex: ThemesView(model: model)
                    case .trash:       TrashView(model: model)
                    default:
                        if model.browseMode == .grid {
                            EntryGridView(model: model)
                        } else {
                            EntryListView(model: model)
                        }
                    }
                }
                .frame(minWidth: 320)
                .toolbar {
                    ToolbarItem {
                        Picker("视图", selection: $model.browseMode) {
                            Image(systemName: "rectangle.grid.1x2").tag(BrowseMode.list)
                            Image(systemName: "square.grid.2x2").tag(BrowseMode.grid)
                        }
                        .pickerStyle(.segmented)
                        .help("列表 / 卡片")
                    }
                }
            } detail: {
                DocView(model: model)
            }
        }
        .focusedSceneValue(\.appModel, model)
    }
}
