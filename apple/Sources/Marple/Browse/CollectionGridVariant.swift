import SwiftUI
import AppKit
import MarpleKit

/// Variant ② — native `NSCollectionView` with a custom waterfall layout and a
/// **pure-AppKit cell** (`EntryCardItem`, drawn with `NSImageView`/`NSTextField`,
/// no `NSHostingView`). This is the path that fits the AppKit-first stack
/// (matches the NSTableView list / NSOutlineView sidebar) and buys Mac-standard
/// interactions for free: cell-recycled scrolling, single-click select, ⌘/⇧
/// multi-select, rubber-band marquee, item dragging (writes the entry path), and
/// double-click to open. No SwiftUI bridge → none of the earlier crash.
struct CollectionGridVariant: NSViewRepresentable {
    let model: AppModel
    let dims: GridDimensions
    let columnWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(model: model, dims: dims) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let collectionView = ClickableCollectionView()
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.onOpen = { [weak coordinator] item in
            guard let entry = coordinator?.entries[safe: item] else { return }
            Task { await coordinator?.model.open(entry.path) }
        }
        collectionView.onDragPath = { [weak coordinator] item in
            coordinator?.entries[safe: item]?.path
        }
        collectionView.menuForItem = { [weak coordinator] item in
            coordinator?.contextMenu(forItem: item)
        }

        let layout = WaterfallCollectionLayout()
        layout.columnWidth = columnWidth
        layout.heightForItem = { [weak coordinator] index, width in
            guard let coordinator, let entry = coordinator.entries[safe: index] else { return 200 }
            let live = coordinator.collectionView?.inLiveResize ?? false
            return coordinator.dims.estimatedHeight(for: entry, columnWidth: width, allowStale: live)
        }
        collectionView.collectionViewLayout = layout
        coordinator.collectionView = collectionView

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        coordinator.entries = model.visibleEntries
        collectionView.reloadData()
        coordinator.trackDims()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let collectionView = coordinator.collectionView,
              let layout = collectionView.collectionViewLayout as? WaterfallCollectionLayout else { return }

        if layout.columnWidth != columnWidth {
            layout.columnWidth = columnWidth
            layout.invalidateLayout()
        }
        let newEntries = model.visibleEntries
        if newEntries.map(\.path) != coordinator.entries.map(\.path) {
            coordinator.entries = newEntries
            dims.invalidateHeights()
            collectionView.reloadData()
            coordinator.trackDims()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: AppModel
        let dims: GridDimensions
        var entries: [Entry] = []
        weak var collectionView: NSCollectionView?

        init(model: AppModel, dims: GridDimensions) {
            self.model = model
            self.dims = dims
        }

        func numberOfSections(in _: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection _: Int) -> Int { entries.count }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            // Instantiate directly (no register/makeItem): this SPM executable has
            // no main bundle, and class registration makes NSCollectionViewItem
            // auto-load a nib named after the class, which throws. Passing
            // nibName: nil + our code-based loadView avoids it entirely.
            let item = EntryCardItem(nibName: nil, bundle: nil)
            guard let entry = entries[safe: indexPath.item] else { return item }
            dims.probe(entry)
            let nonConforming = model.conformance(for: entry)?.isConforming == false
            item.configure(entry: entry, nonConforming: nonConforming) { [model] path in
                try? await model.client.imageOriginalURL(forImageEntryPath: path)
            }
            return item
        }

        /// Right-click menu for a card: open, open in new tab, and "open in Space →"
        /// (the same `openInSpace` the drag uses — a reliable, drag-free trigger).
        func contextMenu(forItem index: Int) -> NSMenu? {
            guard let entry = entries[safe: index] else { return nil }
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "打开") { [weak self] in
                Task { await self?.model.open(entry.path) } })
            menu.addItem(ClosureMenuItem(title: "新标签打开") { [weak self] in
                Task { await self?.model.openInNewTab(entry.path) } })
            menu.addItem(.separator())
            let spacesItem = NSMenuItem(title: "在 Space 中打开", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (i, space) in model.spaces.enumerated() {
                let title = space.name.isEmpty ? "Space \(i + 1)" : space.name
                submenu.addItem(ClosureMenuItem(title: title) { [weak self] in
                    Task { await self?.model.openInSpace(entry.path, space: space.id) } })
            }
            spacesItem.submenu = submenu
            menu.addItem(spacesItem)
            return menu
        }

        /// Re-arm an Observation watch so finished aspect-ratio probes invalidate
        /// the layout (cards settle to true height as bitmaps resolve).
        func trackDims() {
            withObservationTracking {
                for entry in entries where entry.type == .image {
                    _ = dims.aspect(for: entry.path)
                }
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.collectionView?.collectionViewLayout?.invalidateLayout()
                    self.trackDims()
                }
            }
        }
    }
}

/// NSMenuItem that fires a closure — avoids target/action + representedObject plumbing.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// NSCollectionView with double-click-to-open and a **manual** item drag.
///
/// NSCollectionView's built-in (`pasteboardWriterForItemAt`) drag would not
/// deliver to destinations outside the collection view — the drag image showed
/// but no Space drop target ever got `draggingEntered`. So we start the drag
/// ourselves via `beginDraggingSession` (the same mechanism the sidebar Space
/// reorder uses, which does deliver), suppressing the built-in one by not
/// forwarding `mouseDragged` to super. QUA-114.
private final class ClickableCollectionView: NSCollectionView {
    var onOpen: ((Int) -> Void)?
    var onDragPath: ((Int) -> String?)?
    var menuForItem: ((Int) -> NSMenu?)?
    private var selectionAnchor: Int?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexPathForItem(at: point)?.item else { return nil }
        return menuForItem?(index)
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Offer BOTH: the tab outline accepts with .move, the Space dot with .copy.
        // The destination's returned op must intersect this mask or the drop is rejected.
        [.copy, .move]
    }

    /// We run our OWN click-vs-drag tracking loop instead of calling
    /// `super.mouseDown`. NSCollectionView's mouseDown enters a modal tracking
    /// loop that swallows the `mouseDragged` events, so an overridden
    /// `mouseDragged` never fires and our manual drag session never starts (the
    /// symptom: no real drag animation, nothing delivered). Peeking the events
    /// here lets us begin a true `beginDraggingSession` that DOES reach the
    /// sidebar Space drop targets, while still handling click-select + double-click.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexPathForItem(at: point)?.item else {
            selectionAnchor = nil
            super.mouseDown(with: event)   // empty area: marquee / deselect
            return
        }
        if event.clickCount == 2 { onOpen?(index); return }

        let ip = IndexPath(item: index, section: 0)
        let start = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                selectClick(index, modifiers: event.modifierFlags)
                return
            }
            let p = next.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { continue }
            // Drag the whole selection if this card is part of it; otherwise this
            // is a fresh single drag — select it first, then drag just it.
            let dragIndices: [Int]
            if selectionIndexPaths.contains(ip) {
                dragIndices = selectionIndexPaths.map(\.item).sorted()
            } else {
                deselectItems(at: selectionIndexPaths)
                selectItems(at: [ip], scrollPosition: [])
                selectionAnchor = index
                dragIndices = [index]
            }
            startManualDrag(indices: dragIndices, event: next)
            return
        }
    }

    /// Click selection: ⇧ = range from anchor, ⌘ = toggle, plain = single.
    private func selectClick(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        let ip = IndexPath(item: index, section: 0)
        if modifiers.contains(.shift), let anchor = selectionAnchor {
            let range = Set((min(anchor, index)...max(anchor, index)).map { IndexPath(item: $0, section: 0) })
            deselectItems(at: selectionIndexPaths.subtracting(range))
            selectItems(at: range, scrollPosition: [])
        } else if modifiers.contains(.command) {
            if selectionIndexPaths.contains(ip) { deselectItems(at: [ip]) }
            else { selectItems(at: [ip], scrollPosition: []) }
            selectionAnchor = index
        } else {
            deselectItems(at: selectionIndexPaths)
            selectItems(at: [ip], scrollPosition: [])
            selectionAnchor = index
        }
    }

    /// Begin a drag carrying one `entry:<path>` pasteboard item per selected card
    /// (the SAME payload as a tab drag). Multiple items stack into a pile image and
    /// arrive on the drop side as multiple payloads → the tab outline's multi-drop.
    private func startManualDrag(indices: [Int], event: NSEvent) {
        let items: [NSDraggingItem] = indices.compactMap { i in
            guard let path = onDragPath?(i) else { return nil }
            let pb = NSPasteboardItem()
            pb.setString("entry:\(path)", forType: SidebarDragPasteboard.tabItem)
            let dragItem = NSDraggingItem(pasteboardWriter: pb)
            let frame = layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame
                ?? NSRect(origin: convert(event.locationInWindow, from: nil),
                          size: NSSize(width: 220, height: 80))
            dragItem.setDraggingFrame(frame, contents: itemSnapshot(i))
            return dragItem
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    private func itemSnapshot(_ index: Int) -> NSImage? {
        guard let view = item(at: IndexPath(item: index, section: 0))?.view,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// During live resize the layout repacks with stale (cached) heights for
    /// speed; once the drag ends, recompute precise heights for the final width.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        collectionViewLayout?.invalidateLayout()
    }
}
