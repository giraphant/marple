import SwiftUI
import AppKit
import Quartz
import MarpleKit

/// Native collection browsing with reusable AppKit cells and a regular flow layout.
struct CollectionGridVariant: NSViewRepresentable {
    let model: AppModel
    let columnWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let collectionView = ClickableCollectionView()
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.setAccessibilityLabel(String(localized: "资料网格"))
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
        collectionView.previewURL = { [weak coordinator] item in
            guard let coordinator, let entry = coordinator.entries[safe: item] else { return nil }
            if entry.type == .image {
                return try? await coordinator.model.client.imageOriginalURL(forImageEntryPath: entry.path)
            }
            return coordinator.model.client.fileURL(for: entry.path)
        }

        let layout = EntryGridLayout()
        layout.preferredItemWidth = columnWidth
        collectionView.collectionViewLayout = layout
        // Setting the first modern layout replaces AppKit's legacy core. Register
        // afterward, or makeItem loses the class and tries to load a nonexistent nib.
        collectionView.register(EntryCardItem.self, forItemWithIdentifier: .init("EntryCard"))
        coordinator.collectionView = collectionView

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        coordinator.entries = model.visibleEntries
        collectionView.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let collectionView = coordinator.collectionView,
              let layout = collectionView.collectionViewLayout as? EntryGridLayout else { return }

        let resized = layout.preferredItemWidth != columnWidth
        let scale = collectionView.window?.backingScaleFactor ?? 2
        let refreshThumbnails = ThumbnailLoader.maxPixel(columnWidth: layout.preferredItemWidth, scale: scale)
            != ThumbnailLoader.maxPixel(columnWidth: columnWidth, scale: scale)
        if resized { layout.preferredItemWidth = columnWidth }
        var selected = Set(collectionView.selectionIndexPaths.compactMap {
            coordinator.entries[safe: $0.item]?.path
        })
        let openPath = model.openPath
        let openedAnotherEntry = openPath != coordinator.lastOpenPath
        if openedAnotherEntry {
            selected = Set(openPath.map { [$0] } ?? [])
            coordinator.lastOpenPath = openPath
        }
        let newEntries = model.visibleEntries
        if newEntries != coordinator.entries {
            coordinator.entries = newEntries
            collectionView.reloadData()
        } else if refreshThumbnails {
            // Re-decode only when crossing a pixel-size bucket, not every slider tick.
            collectionView.reloadItems(at: collectionView.indexPathsForVisibleItems())
        }
        let indices = Set(newEntries.indices.filter { selected.contains(newEntries[$0].path) }
            .map { IndexPath(item: $0, section: 0) })
        if collectionView.selectionIndexPaths != indices {
            collectionView.selectionIndexPaths = indices
        }
        if openedAnotherEntry, !indices.isEmpty {
            collectionView.scrollToItems(at: indices, scrollPosition: .nearestHorizontalEdge.union(.nearestVerticalEdge))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: AppModel
        var entries: [Entry] = []
        var lastOpenPath: String?
        weak var collectionView: NSCollectionView?

        init(model: AppModel) {
            self.model = model
        }

        func numberOfSections(in _: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection _: Int) -> Int { entries.count }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .init("EntryCard"), for: indexPath) as! EntryCardItem
            guard let entry = entries[safe: indexPath.item] else { return item }
            let nonConforming = model.conformance(for: entry)?.isConforming == false
            // Decode the thumbnail only as large as this card can show it (column width ×
            // backing scale), not at the source resolution — see ThumbnailLoader (QUA-219).
            let columnWidth = (collectionView.collectionViewLayout as? EntryGridLayout)?.preferredItemWidth ?? 136
            let scale = collectionView.window?.backingScaleFactor ?? 2
            let maxPixel = ThumbnailLoader.maxPixel(columnWidth: columnWidth, scale: scale)
            item.configure(entry: entry, nonConforming: nonConforming, maxPixel: maxPixel) { [model] path in
                try? await model.client.imageOriginalURL(forImageEntryPath: path)
            }
            return item
        }

        /// Right-click menu for a card: open, open in new tab, and "open in Space →"
        /// (the same `openInSpace` the drag uses — a reliable, drag-free trigger).
        func contextMenu(forItem index: Int) -> NSMenu? {
            guard let entry = entries[safe: index] else { return nil }
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: String(localized: "打开")) { [weak self] in
                Task { await self?.model.open(entry.path) } })
            menu.addItem(ClosureMenuItem(title: String(localized: "新标签打开")) { [weak self] in
                Task { await self?.model.openInNewTab(entry.path) } })
            menu.addItem(.separator())
            let spacesItem = NSMenuItem(title: String(localized: "在空间中打开"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (i, space) in model.spaces.enumerated() {
                let title = space.name.isEmpty ? String(localized: "空间 \(i + 1)") : space.name
                submenu.addItem(ClosureMenuItem(title: title) { [weak self] in
                    Task { await self?.model.openInSpace(entry.path, space: space.id) } })
            }
            spacesItem.submenu = submenu
            menu.addItem(spacesItem)
            return menu
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
final class ClickableCollectionView: NSCollectionView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onOpen: ((Int) -> Void)?
    var onDragPath: ((Int) -> String?)?
    var menuForItem: ((Int) -> NSMenu?)?
    /// Resolve the file URL to Quick Look for an item (image original / vault .md).
    var previewURL: ((Int) async -> URL?)?
    private var selectionAnchor: Int?
    private var quickLookURLs: [URL] = []

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        // Update metrics before AppKit calculates rows for the new viewport.
        // Doing this inside layout.prepare() leaves its cached row geometry stale.
        if frame.width != newSize.width {
            (collectionViewLayout as? EntryGridLayout)?.updateMetrics(width: newSize.width)
        }
        super.setFrameSize(newSize)
    }

    private var focusedIndex: Int? {
        if let selectionAnchor, selectionIndexPaths.contains(IndexPath(item: selectionAnchor, section: 0)) {
            return selectionAnchor
        }
        return selectionIndexPaths.map(\.item).min()
    }

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
        window?.makeFirstResponder(self)   // so arrow keys / space act on the grid
        if event.clickCount == 2 { onOpen?(index); return }

        let ip = IndexPath(item: index, section: 0)
        let start = event.locationInWindow
        // Keep an existing group intact until mouse-up so pressing a selected
        // item can drag the group. Fresh selections respond on mouse-down.
        let collapseOnMouseUp = selectionIndexPaths.contains(ip) && selectionIndexPaths.count > 1
            && event.modifierFlags.intersection([.command, .shift]).isEmpty
        if !collapseOnMouseUp { selectClick(index, modifiers: event.modifierFlags) }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if collapseOnMouseUp { selectClick(index, modifiers: event.modifierFlags) }
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
    func selectClick(_ index: Int, modifiers: NSEvent.ModifierFlags) {
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
        let items = draggingItems(indices: indices, location: convert(event.locationInWindow, from: nil))
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingItems(indices: [Int], location: NSPoint) -> [NSDraggingItem] {
        indices.compactMap { i in
            guard let path = onDragPath?(i) else { return nil }
            let pb = NSPasteboardItem()
            pb.setString("entry:\(path)", forType: SidebarDragPasteboard.tabItem)
            let dragItem = NSDraggingItem(pasteboardWriter: pb)
            let frame = layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame
                ?? NSRect(origin: location, size: NSSize(width: 136, height: 180))
            dragItem.setDraggingFrame(frame, contents: itemSnapshot(i))
            return dragItem
        }
    }

    private func itemSnapshot(_ index: Int) -> NSImage? {
        guard let view = item(at: IndexPath(item: index, section: 0))?.view,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // return / enter → open
            if let i = focusedIndex { onOpen?(i) }
        case 49:       // space → Quick Look
            showQuickLook()
        default:
            super.keyDown(with: event)
            selectionAnchor = selectionIndexPaths.map(\.item).min()
            if (123...126).contains(event.keyCode),
               QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                showQuickLook()
            }
        }
    }

    // MARK: Quick Look (space)

    private func showQuickLook() {
        let selected = selectionIndexPaths.map(\.item).sorted()
        let ordered = focusedIndex.map { f in [f] + selected.filter { $0 != f } } ?? selected
        guard !ordered.isEmpty else { return }
        Task { @MainActor in
            var urls: [URL] = []
            for i in ordered { if let u = await previewURL?(i) { urls.append(u) } }
            guard !urls.isEmpty else { return }
            quickLookURLs = urls
            guard let panel = QLPreviewPanel.shared() else { return }
            if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Quick Look panel control callbacks always arrive on the main thread, but
        // the override is declared nonisolated; assert isolation to set the
        // @MainActor dataSource/delegate without changing runtime behavior.
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookURLs.count }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let url: URL? = MainActor.assumeIsolated {
            quickLookURLs.indices.contains(index) ? quickLookURLs[index] : nil
        }
        return url as NSURL?
    }
}
