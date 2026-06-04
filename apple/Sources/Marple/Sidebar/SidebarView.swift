import AppKit
import SwiftUI
import MarpleKit

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SidebarOutlineView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            SpaceSwitcherView(model: model)
                .frame(height: 46)
        }
        .navigationTitle("Marple")
    }
}

private struct SpaceSwitcherView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.select(pane: .trash)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.pane == .trash && model.isBrowsing ? .primary : .secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceControlView(index: index + 1,
                                     spaceID: space.id,
                                     iconName: space.iconName,
                                     isActive: model.activeSpaceID == space.id,
                                     model: model)
                        .frame(width: 28, height: 28)
                }
            }

            Spacer(minLength: 4)

            Button {
                model.addSpace()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
    }
}

private enum SpaceDragPasteboard {
    static let spaceItem = NSPasteboard.PasteboardType("com.marple.space-item")
}

private struct SpaceIconPaletteView: View {
    let choose: (String?) -> Void

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 5)
    private let iconChoices = [
        "star.fill", "bookmark.fill", "flag.fill", "bolt.fill",
        "lightbulb.fill", "brain", "globe.asia.australia.fill", "building.columns.fill", "person.2.fill",
        "quote.bubble.fill", "book.fill", "doc.text.fill", "newspaper.fill", "graduationcap.fill",
        "theatermasks.fill", "camera.fill", "paintpalette.fill", "music.note", "film.fill",
        "gamecontroller.fill", "leaf.fill", "tree.fill", "pawprint.fill", "ladybug.fill",
        "cloud.fill", "sun.max.fill", "moon.fill", "mountain.2.fill", "water.waves",
        "flame.fill", "atom", "function", "chart.xyaxis.line", "cylinder.split.1x2.fill",
        "network", "terminal.fill", "hammer.fill", "wrench.and.screwdriver.fill", "shield.fill",
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            Button("123") { choose(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())

            ForEach(iconChoices, id: \.self) { symbol in
                Button { choose(symbol) } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .frame(width: 156)
        .padding(6)
    }
}

/// A Space dot that also accepts a dragged browse card (`.string` entry path) via
private struct SpaceControlView: NSViewRepresentable {
    let index: Int
    let spaceID: WorkspaceSpace.ID
    let iconName: String?
    let isActive: Bool
    var model: AppModel

    func makeNSView(context: Context) -> SpaceControl {
        let view = SpaceControl()
        view.registerForDraggedTypes([SidebarDragPasteboard.tabItem, SpaceDragPasteboard.spaceItem])
        return view
    }

    func updateNSView(_ view: SpaceControl, context: Context) {
        view.index = index
        view.spaceID = spaceID
        view.iconName = iconName
        view.isActive = isActive
        view.model = model
        view.needsDisplay = true
    }

    @MainActor final class SpaceControl: NSView, NSDraggingSource {
        var index: Int = 1
        var spaceID: WorkspaceSpace.ID?
        var iconName: String?
        var isActive = false
        weak var model: AppModel?

        private var mouseDownEvent: NSEvent?
        private var didStartDrag = false
        private var hoverGeneration = 0
        private var switchScheduled = false
        private var iconPopover: NSPopover?
        private let dragThreshold: CGFloat = 3

        override var acceptsFirstResponder: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
        }

        override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if isActive {
                let rect = bounds.insetBy(dx: 1, dy: 1)
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            }

            let color = isActive ? NSColor.labelColor : NSColor.secondaryLabelColor
            if let iconName,
               let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                drawSymbol(image, color: color)
            } else {
                drawNumber(color: color)
            }
        }

        private func drawSymbol(_ image: NSImage, color: NSColor) {
            guard let configured = image.withSymbolConfiguration(.init(pointSize: 14, weight: isActive ? .semibold : .medium)) else { return }
            let maxSize: CGFloat = 16
            let imageSize = configured.size
            let scale = min(maxSize / imageSize.width, maxSize / imageSize.height)
            let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let rect = NSRect(x: bounds.midX - drawSize.width / 2,
                              y: bounds.midY - drawSize.height / 2,
                              width: drawSize.width,
                              height: drawSize.height)
            color.set()
            configured.draw(in: rect,
                            from: NSRect(origin: .zero, size: imageSize),
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: nil)
        }

        private func drawNumber(color: NSColor) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: isActive ? .semibold : .medium),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            let text = "\(index)" as NSString
            let textHeight = text.size(withAttributes: attrs).height
            let rect = NSRect(x: 0, y: bounds.midY - textHeight / 2 - 0.5,
                              width: bounds.width, height: textHeight)
            text.draw(in: rect, withAttributes: attrs)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            didStartDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !didStartDrag,
                  let mouseDownEvent,
                  let spaceID else { return }
            let start = mouseDownEvent.locationInWindow
            let current = event.locationInWindow
            guard hypot(current.x - start.x, current.y - start.y) >= dragThreshold else { return }
            didStartDrag = true

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(spaceID.uuidString, forType: SpaceDragPasteboard.spaceItem)
            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            draggingItem.setDraggingFrame(bounds, contents: snapshotImage())
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownEvent = nil
                didStartDrag = false
            }
            guard !didStartDrag, let spaceID else { return }
            Task { await model?.selectSpace(spaceID) }
        }

        override func rightMouseDown(with event: NSEvent) {
            showIconPalette(at: convert(event.locationInWindow, from: nil))
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .move
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            mouseDownEvent = nil
            didStartDrag = false
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            draggingUpdated(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            if let draggedSpace = draggedSpaceID(from: sender) {
                guard let target = spaceID, draggedSpace != target else { return [] }
                let point = convert(sender.draggingLocation, from: nil)
                if point.x < bounds.midX {
                    model?.moveSpace(draggedSpace, before: target)
                } else {
                    model?.moveSpace(draggedSpace, after: target)
                }
                return .move
            }
            if hasSidebarPayload(sender) {
                scheduleSpaceSwitch()
                return .move
            }
            return []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            cancelSwitch()
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            cancelSwitch()
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            draggedSpaceID(from: sender) != nil
        }

        private func draggedSpaceID(from sender: NSDraggingInfo) -> WorkspaceSpace.ID? {
            sender.draggingPasteboard.string(forType: SpaceDragPasteboard.spaceItem)
                .flatMap(UUID.init(uuidString:))
        }

        private func hasSidebarPayload(_ sender: NSDraggingInfo) -> Bool {
            sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [SidebarDragPasteboard.tabItem.rawValue])
        }

        private func scheduleSpaceSwitch() {
            guard !isActive, !switchScheduled, let target = spaceID else { return }
            switchScheduled = true
            hoverGeneration += 1
            let generation = hoverGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard let self, self.hoverGeneration == generation, !self.isActive else { return }
                self.switchScheduled = false
                await self.model?.selectSpace(target)
            }
        }

        private func cancelSwitch() {
            hoverGeneration += 1
            switchScheduled = false
        }

        private func snapshotImage() -> NSImage {
            guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
                return NSImage(size: bounds.size)
            }
            cacheDisplay(in: bounds, to: rep)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            return image
        }

        private func showIconPalette(at point: NSPoint) {
            guard spaceID != nil else { return }
            iconPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentSize = NSSize(width: 168, height: 292)
            popover.contentViewController = NSHostingController(rootView: SpaceIconPaletteView { [weak self] symbol in
                guard let self, let spaceID = self.spaceID else { return }
                self.model?.setSpaceIcon(symbol, for: spaceID)
                self.iconPopover?.close()
            })
            iconPopover = popover
            popover.show(relativeTo: NSRect(origin: point, size: .zero), of: self, preferredEdge: .maxY)
        }
    }
}
