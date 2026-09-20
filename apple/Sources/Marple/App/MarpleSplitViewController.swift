import AppKit
import SwiftUI
import MarpleKit

/// The window's content: an `NSSplitViewController` we own (Notes / Mail / CodeEdit
/// pattern), hosting the SwiftUI columns via `NSHostingController`. Owning the
/// split (rather than embedding it in an `NSHostingController`) is what makes the
/// sidebar/inspector behaviors, min widths, and toolbar tracking separators work —
/// CodeEdit explicitly abandoned the embedded approach for this reason.
@MainActor
final class MarpleSplitViewController: NSSplitViewController {
    private let model: AppModel
    private var sidebarItem: NSSplitViewItem?
    private var listItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    private var inspectorObs: NSKeyValueObservation?
    private var readerController: NSViewController!
    private var propertiesController: NSViewController!
    private var detailSplit: NSSplitViewController?
    private var appliedThreeColumnLayout: Bool?
    private var needsDetailSizing = false
    var onLayoutChange: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Hosting controller that fills its split pane without driving the window/pane
    /// size. Default `NSHostingController` propagates its content's fitting size,
    /// which shrank the whole window when a column's content got small (e.g. the
    /// empty-reader placeholder) and tipped the sidebar into overlay mode.
    private func host<V: View>(_ view: V) -> NSHostingController<V> {
        let hc = NSHostingController(rootView: view)
        hc.sizingOptions = []
        return hc
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSSplitViewItem(sidebarWithViewController:
            host(Chrome { SidebarView(model: model) }))
        sidebar.minimumThickness = 220
        sidebar.collapseBehavior = .useConstraints
        sidebar.isSpringLoaded = true
        addSplitViewItem(sidebar)
        sidebarItem = sidebar

        // The list column collapses by dragging it past its min (Ulysses-style):
        // spring-loading + minimumThickness is all that's needed (CodeEdit's note).
        let content = NSSplitViewItem(viewController:
            host(Chrome { BrowseColumn(model: model) }))
        content.minimumThickness = 320
        content.titlebarSeparatorStyle = .line
        content.canCollapse = true
        content.collapseBehavior = .useConstraints
        content.isSpringLoaded = true
        content.holdingPriority = NSLayoutConstraint.Priority(260)   // list holds its width
        addSplitViewItem(content)
        listItem = content

        readerController = host(Chrome { DocView(model: model) })
        propertiesController = host(Chrome { InspectorView(model: model) })
        applyLayout()

        observeModelInspector()
    }

    /// Move the same reader and property controllers between layouts, keeping
    /// their scroll/edit state. No second reader (or media player) is mounted.
    private func applyLayout() {
        guard appliedThreeColumnLayout != model.threeColumnLayout else { return }
        appliedThreeColumnLayout = model.threeColumnLayout
        splitView.window?.toolbar = nil // detach tracking separators before removing dividers
        inspectorObs = nil
        for item in splitViewItems.dropFirst(2) { removeSplitViewItem(item) }
        if let detailSplit {
            for item in detailSplit.splitViewItems { detailSplit.removeSplitViewItem(item) }
        }
        detailSplit = nil

        let inspector: NSSplitViewItem
        if model.threeColumnLayout {
            let right = NSSplitViewController()
            right.splitView.isVertical = false
            right.splitView.dividerStyle = .thin
            let preview = NSSplitViewItem(viewController: readerController)
            preview.minimumThickness = 260
            preview.preferredThicknessFraction = 0.4
            right.addSplitViewItem(preview)
            let properties = NSSplitViewItem(viewController: propertiesController)
            properties.minimumThickness = 180
            right.addSplitViewItem(properties)
            detailSplit = right
            needsDetailSizing = true
            inspector = NSSplitViewItem(viewController: right)
            inspector.minimumThickness = 344
            inspector.maximumThickness = 560
            inspector.preferredThicknessFraction = 0.32
            inspector.canCollapse = true
            inspector.holdingPriority = NSLayoutConstraint.Priority(260)
            listItem?.holdingPriority = NSLayoutConstraint.Priority(248)
        } else {
            let detail = NSSplitViewItem(viewController: readerController)
            detail.minimumThickness = 400
            detail.holdingPriority = NSLayoutConstraint.Priority(248)
            addSplitViewItem(detail)
            inspector = NSSplitViewItem(inspectorWithViewController: propertiesController)
            inspector.minimumThickness = 240
            inspector.maximumThickness = 460
            inspector.isSpringLoaded = true
            listItem?.holdingPriority = NSLayoutConstraint.Priority(260)
        }
        inspector.collapseBehavior = .useConstraints
        inspector.isCollapsed = !model.inspectorVisible || (!model.threeColumnLayout && model.openPath == nil)
        addSplitViewItem(inspector)
        inspectorItem = inspector
        inspectorObs = inspector.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self, self.model.threeColumnLayout || self.model.openPath != nil else { return }
                if self.model.inspectorVisible == collapsed { self.model.inspectorVisible = !collapsed }
            }
        }
        onLayoutChange?()
        if view.window?.isVisible == true { sizePreviewIfNeeded() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        sizePreviewIfNeeded()
    }

    private func sizePreviewIfNeeded() {
        guard needsDetailSizing, let detailSplit else { return }
        view.layoutSubtreeIfNeeded()
        needsDetailSizing = false
        detailSplit.splitView.setPosition(detailSplit.view.bounds.height * 0.4, ofDividerAt: 0)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyInspector()
    }

    /// One button, Ulysses-style: if either the sidebar or the list is collapsed,
    /// expand both; if both are already open, collapse just the sidebar.
    func toggleNavigation() {
        guard let sidebar = sidebarItem, let list = listItem else { return }
        if sidebar.isCollapsed || list.isCollapsed {
            sidebar.animator().isCollapsed = false
            list.animator().isCollapsed = false
        } else {
            sidebar.animator().isCollapsed = true
        }
    }

    /// React to `model.inspectorVisible` / `model.openPath` via Observation (there's
    /// no SwiftUI parent to drive this for us anymore).
    private func observeModelInspector() {
        withObservationTracking {
            _ = model.threeColumnLayout
            _ = model.inspectorVisible
            _ = model.openPath
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyLayout()
                self?.applyInspector()
                self?.observeModelInspector()
            }
        }
    }

    private func applyInspector() {
        guard let inspectorItem else { return }
        let visible = model.inspectorVisible && (model.threeColumnLayout || model.openPath != nil)
        if inspectorItem.isCollapsed == visible {
            inspectorItem.animator().isCollapsed = !visible
        }
    }
}

/// Re-applies the `@AppStorage`-driven reading-font environment inside each hosted
/// column, since each `NSHostingController` is its own SwiftUI tree.
private struct Chrome<Content: View>: View {
    @AppStorage(SettingsKeys.readingFontFamily) private var fontFamily = ReadingFontFamily.sans
    @AppStorage(SettingsKeys.readingFontSize) private var fontSize = ReadingDefaults.fontSize
    @AppStorage(SettingsKeys.readingLineHeight) private var lineHeight = ReadingDefaults.lineHeight
    @AppStorage(SettingsKeys.readingLetterSpacing) private var letterSpacing = ReadingDefaults.letterSpacing
    @ViewBuilder var content: Content

    private var readingFont: ReadingFontConfig {
        ReadingFontConfig(size: fontSize, fontFamily: fontFamily.systemFamily,
                          bodyWeight: fontFamily.bodyWeight, lineHeight: lineHeight,
                          letterSpacing: letterSpacing)
    }

    var body: some View {
        content.environment(\.readingFont, readingFont)
    }
}

struct IndexLoadingPresentation {
    let isBootstrapping: Bool
    let isFirstRun: Bool

    var title: String? {
        guard isBootstrapping else { return nil }
        return isFirstRun ? String(localized: "首次建立索引") : String(localized: "正在加载索引")
    }

    var message: String {
        isFirstRun
        ? String(localized: "正在解析您的文库，首次启动可能需要几分钟。完成后会自动加载，无需手动刷新。")
        : String(localized: "正在读取本地索引，完成后会自动加载。")
    }
}

/// The middle column (browse list/grid, or themes/trash), lifted out of RootView so
/// it can be hosted on its own.
struct BrowseColumn: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if model.isPinnedListContext {
                if model.threeColumnLayout && model.browseMode == .grid {
                    EntryGridView(model: model)
                } else {
                    EntryListView(model: model)
                }
            } else {
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
        // QUA-105: fade the list/grid in when bootstrap completes. During
        // bootstrap the visibleEntries snapshot is empty (skeleton state); the
        // 0→1 opacity transition replaces what used to be a hard "pop" when
        // the first loadIndex published its snapshot. Sidebar isn't faded
        // because its restored selection is already legitimate from t=0.
        .opacity(model.isBootstrapping ? 0.0 : 1.0)
        .animation(.easeOut(duration: 0.22), value: model.isBootstrapping)
        .overlay {
            let presentation = IndexLoadingPresentation(isBootstrapping: model.isBootstrapping,
                                                        isFirstRun: model.isFirstRun)
            if let title = presentation.title {
                ContentUnavailableView {
                    Label(title, systemImage: "books.vertical")
                } description: {
                    Text(presentation.message)
                } actions: {
                    ProgressView().controlSize(.small)
                }
                .transition(.opacity)
            }
        }
        // A second animation scope covers the overlay transition.
        .animation(.easeOut(duration: 0.22), value: model.isBootstrapping)
    }
}
