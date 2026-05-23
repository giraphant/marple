import SwiftUI
import MarpleKit

/// The booted app shell (Ulysses/CodeEdit layout): BOTH side rails are full-height,
/// first-class columns — left sidebar + right inspector — with the tab strip +
/// back/forward in a bar over the content+reader area between them. content|reader
/// split via HSplitView. The titlebar holds icon actions, organized left/right.
struct RootView: View {
    @Bindable var model: AppModel
    @State private var inspectorShown = true

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .frame(minWidth: 220)
        } detail: {
            VStack(spacing: 0) {
                TabStripView(model: model)
                Divider()
                HSplitView {
                    contentColumn
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
                    DocView(model: model)
                        .frame(minWidth: 380)
                }
            }
            .inspector(isPresented: $inspectorShown) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
            }
            .toolbar { toolbarContent }
        }
        .focusedSceneValue(\.appModel, model)
    }

    /// Titlebar actions, organized by side: new-content on the left (near the
    /// sidebar), view/document/inspector controls on the right (near the reader +
    /// inspector). All icons; meaning rides on .help tooltips.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { Task { await model.newIdeaNote() } } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("新建笔记")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("视图", selection: $model.browseMode) {
                Image(systemName: "rectangle.grid.1x2").tag(BrowseMode.list)
                Image(systemName: "square.grid.2x2").tag(BrowseMode.grid)
            }
            .pickerStyle(.segmented)
            .help("列表 / 卡片")

            Button { Task { await model.newAnnotationForOpenDoc() } } label: {
                Image(systemName: "note.text.badge.plus")
            }
            .help("新建批注")
            .disabled(model.openEntry == nil)

            Button { Task { await model.openExternally() } } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .help("用外部编辑器打开")
            .disabled(model.openPath == nil)

            Button { inspectorShown.toggle() } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("检查器")
        }
    }

    @ViewBuilder private var contentColumn: some View {
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
}
