import SwiftUI
import MarpleKit

/// The booted app shell (Arc-style): a first-class sidebar that holds categories
/// AND the open tabs (vertical) — so there is no horizontal tab strip / double
/// header. The main area shows ONE full-width view per active tab: full-width
/// browse (grid spreads out / list) when no doc is open, or the reader when a doc
/// is open. The inspector is a right rail that appears only while reading.
struct RootView: View {
    @Bindable var model: AppModel
    @State private var inspectorShown = true

    @AppStorage(SettingsKeys.theme) private var theme = ThemePreference.system
    @AppStorage(SettingsKeys.readingFontFamily) private var fontFamily = ReadingFontFamily.sans
    @AppStorage(SettingsKeys.readingFontSize) private var fontSize = ReadingDefaults.fontSize
    @AppStorage(SettingsKeys.readingLineHeight) private var lineHeight = ReadingDefaults.lineHeight

    private var readingFont: ReadingFontConfig {
        ReadingFontConfig(size: fontSize, design: fontFamily.design, lineHeight: lineHeight)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .frame(minWidth: 220)
        } content: {
            browseColumn
                .frame(minWidth: 320)
                .toolbar { toolbarContent }
        } detail: {
            DocView(model: model)
                .inspector(isPresented: Binding(
                    get: { inspectorShown && model.openPath != nil },
                    set: { inspectorShown = $0 }
                )) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                }
        }
        .focusedSceneValue(\.appModel, model)
        .preferredColorScheme(theme.colorScheme)
        .environment(\.readingFont, readingFont)
    }

    /// The middle column: the browse list/grid for the selected category (or the
    /// themes / trash views). Native 3-column `NavigationSplitView` keeps the reader
    /// in its own detail column — no HSplitView (which clips inside a split detail).
    @ViewBuilder private var browseColumn: some View {
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

    /// Titlebar actions: back/forward on the left; browse view-mode while browsing,
    /// document + inspector actions while reading, on the right. All icons.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await model.goBack() } } label: {
                Image(systemName: "chevron.left")
            }
            .help("后退")
            .disabled(!model.canGoBack)

            Button { Task { await model.goForward() } } label: {
                Image(systemName: "chevron.right")
            }
            .help("前进")
            .disabled(!model.canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("视图", selection: $model.browseMode) {
                Image(systemName: "rectangle.grid.1x2").tag(BrowseMode.list)
                Image(systemName: "square.grid.2x2").tag(BrowseMode.grid)
            }
            .pickerStyle(.segmented)
            .help("列表 / 卡片")

            if model.openPath != nil {
                Button { Task { await model.newAnnotationForOpenDoc() } } label: {
                    Image(systemName: "note.text.badge.plus")
                }
                .help("新建批注")
                .disabled(model.openEntry == nil)

                Button { Task { await model.openExternally() } } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("用外部编辑器打开")

                Button { inspectorShown.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("检查器")
            }
        }
    }
}
