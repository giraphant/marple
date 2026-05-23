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
                    if case .themesIndex = model.pane {
                        ThemesView(model: model)
                    } else {
                        EntryListView(model: model)
                    }
                }
                .frame(minWidth: 320)
            } detail: {
                DocView(model: model)
            }
        }
        .focusedSceneValue(\.appModel, model)
    }
}
