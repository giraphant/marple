import AppKit
import SwiftUI
import Testing
@testable import Marple
@testable import MarpleKit

@Suite(.serialized) @MainActor
struct LibraryGridTests {
    @Test func regularRowsResizeContinuouslyInNarrowPanes() async throws {
        let (window, host, model, collection) = try await makeGrid()
        defer { window.close() }
        collection.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        for width in [320, 420, 540] {
            window.setContentSize(NSSize(width: width, height: 720))
            for size in [120, 136, 180, 248, 260] {
                host.rootView = CollectionGridVariant(model: model, columnWidth: CGFloat(size))
                try await settle(window)
                let frames = try (0..<12).map {
                    try #require(collection.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))).frame
                }
                #expect(frames.allSatisfy { $0.size == frames[0].size })
                #expect(frames[0].width == CGFloat(size))
                #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= collection.bounds.width })
                let columns = max(1, Int((collection.bounds.width - 32 + 12) / CGFloat(size + 12)))
                #expect(frames.filter { $0.minY == frames[0].minY }.count == columns,
                        "pane=\(width) size=\(size) bounds=\(collection.bounds) frames=\(frames.prefix(3))")
                #expect(collection.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
                if size == 136 || size == 180 || size == 248 {
                    try snapshot(host, name: "final-\(width)-\(size)")
                    let start = CFAbsoluteTimeGetCurrent()
                    for _ in 0..<10 {
                        collection.collectionViewLayout?.invalidateLayout()
                        collection.collectionViewLayout?.prepare()
                    }
                    print("GRID_FINAL width=\(width) size=\(size) entries=600 prepare_ms=\((CFAbsoluteTimeGetCurrent()-start)*100) visible=\(collection.indexPathsForVisibleItems().count)")
                }
            }
        }
        window.appearance = NSAppearance(named: .darkAqua)
        host.rootView = CollectionGridVariant(model: model, columnWidth: 136)
        try await settle(window)
        try snapshot(host, name: "final-dark")
    }

    @Test func nativeSelectionAndSpaceDragSurviveUpdates() async throws {
        let (window, host, model, collection) = try await makeGrid()
        defer { window.close() }
        window.makeFirstResponder(collection)
        collection.selectClick(0, modifiers: [])
        #expect(collection.selectionIndexPaths == [IndexPath(item: 0, section: 0)])
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        collection.keyDown(with: right)
        #expect(collection.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        collection.keyDown(with: down)
        #expect(collection.selectionIndexPaths == [IndexPath(item: 4, section: 0)])
        collection.selectClick(0, modifiers: .command)
        #expect(collection.selectionIndexPaths == [IndexPath(item: 0, section: 0), IndexPath(item: 4, section: 0)])
        let selected = [0, 4].map { model.visibleEntries[$0].path }
        let items = collection.draggingItems(indices: [0, 4], location: .zero)
        #expect(items.compactMap { ($0.item as? NSPasteboardItem)?.string(forType: SidebarDragPasteboard.tabItem) }
            == selected.map { "entry:\($0)" })
        #expect(items.allSatisfy { $0.draggingFrame.width > 0 && $0.draggingFrame.height > 0 })
        host.rootView = CollectionGridVariant(model: model, columnWidth: 180)
        try await settle(window)
        #expect(collection.selectionIndexPaths.count == 2)
        model.catalog.mutateEntries { entries in
            entries[0] = entries[0].with(title: "修改后的标题", preview: "修改后的摘要")
        }
        model.catalog.rebuildIndexDerived(savedViews: [])
        model.select(pane: .theme("科学史"))
        try await settle(window)
        #expect(collection.selectionIndexPaths.count == 2)
        let labels = descendants(NSTextField.self, in: try #require(collection.item(at: IndexPath(item: 0, section: 0))).view)
        #expect(labels.contains { $0.stringValue == "修改后的标题" })
        await model.open(model.visibleEntries[8].path)
        try await settle(window)
        #expect(collection.selectionIndexPaths == [IndexPath(item: 8, section: 0)])
    }

    @Test func reusableCardsKeepImageAndTextInsideFixedSlots() async throws {
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("marple-grid-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let image = NSImage(size: NSSize(width: 120, height: 240), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: 0, width: 120, height: 20).fill()
            NSRect(x: 0, y: 220, width: 120, height: 20).fill()
            return true
        }
        try #require(image.tiffRepresentation).write(to: imageURL)
        let item = EntryCardItem(nibName: nil, bundle: nil)
        item.view.frame = NSRect(origin: .zero, size: CardLayout.itemSize(width: 136))
        let window = NSWindow(contentRect: item.view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let surface = NSView(frame: item.view.frame)
        window.contentView = surface
        surface.addSubview(item.view)
        window.orderFront(nil)
        defer { window.close() }
        let photo = fixtureEntries()[3]
        item.configure(entry: photo, nonConforming: false, maxPixel: 384) { _ in imageURL }
        try await Task.sleep(for: .milliseconds(150))
        item.view.layoutSubtreeIfNeeded()
        let thumbnail = try #require(descendants(NSImageView.self, in: item.view).first { $0.image?.size.height == 240 })
        #expect(thumbnail.imageScaling == .scaleProportionallyUpOrDown)
        #expect(item.view.bounds.contains(thumbnail.frame))
        try snapshot(surface, name: "portrait-card")
        item.prepareForReuse()
        item.configure(entry: fixtureEntries()[5], nonConforming: true, maxPixel: 384) { _ in nil }
        item.view.layoutSubtreeIfNeeded()
        #expect(thumbnail.image == nil)
        #expect(item.view.subviews.filter { !$0.isHidden }.allSatisfy { item.view.bounds.contains($0.frame) })
        let fields = descendants(NSTextField.self, in: item.view)
        #expect(fields.count == 3)
        #expect(fields.contains { $0.maximumNumberOfLines == 3 })
        try snapshot(surface, name: "text-card")
    }

    private func makeGrid() async throws -> (NSWindow, NSHostingView<CollectionGridVariant>, AppModel, ClickableCollectionView) {
        let entries = fixtureEntries()
        let model = AppModel(client: StubVaultClient(entries: entries,
            texts: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, "# Sample") })))
        await model.loadIndex()
        model.select(pane: .theme("科学史"))
        let host = NSHostingView(rootView: CollectionGridVariant(model: model, columnWidth: 136))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        try await settle(window)
        let collection = try #require(descendants(ClickableCollectionView.self, in: host).first)
        #expect(collection.numberOfItems(inSection: 0) == 600)
        return (window, host, model, collection)
    }

    private func fixtureEntries() -> [Entry] {
        (0..<600).map { index in
            let titles = ["演化论与目的论", "The Structure of Scientific Revolutions", "读书札记", "历史图像与档案", "解释、证据与科学史", "知识分类中的秩序"]
            let types: [EntryType] = [.paper, .book, .note, .image, .talk, .paper]
            return Entry(path: "sample-\(index).md", type: types[index % 6], title: titles[index % 6],
                author: index % 3 == 0 ? [] : ["Thomas S. Kuhn"], year: "2024",
                ratingScore: Double(index % 6), themes: ["科学史", "研究资料"],
                preview: String(repeating: "理解历史中的自然解释，需要区分过程与目的。", count: 1 + index % 9),
                hasPDF: false, width: index % 6 == 3 ? 600 : nil, height: index % 6 == 3 ? 400 : nil)
        }
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(180))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(type, in: child) }
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["MARPLE_GRID_ABLATION_DIR"] else { return }
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        view.wantsLayer = true
        (view.window?.appearance ?? NSAppearance(named: .aqua))?.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [.compressionFactor: 1]))
            .write(to: root.appendingPathComponent("\(name).png"))
    }
}
