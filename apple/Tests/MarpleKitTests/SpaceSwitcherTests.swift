import AppKit
import SwiftUI
import Testing
@testable import Marple
@testable import MarpleKit

@Suite(.serialized)
@MainActor
struct SpaceSwitcherTests {
    @Test func manySpacesFitTheMinimumSidebarWidth() {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        for count in [1, 4, 6, 20] {
            while model.activeSpaces.count < count { model.addSpace() }
            let host = NSHostingController(rootView: SpaceSwitcherView(model: model))
            let size = host.sizeThatFits(in: NSSize(width: 220, height: 46))
            print("[space layout] \(count) spaces: \(size)")
            #expect(size.width <= 220)
            #expect(size.height <= 46)
        }
    }

    @Test func selectedSpaceRemainsVisibleOnSelectionAndResize() async throws {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        for _ in 1..<20 { model.addSpace() }
        let host = NSHostingView(rootView: SpaceSwitcherView(model: model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 46),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        try await expectSpaceVisible(model.activeSpaceID, in: host)
        let visible = controls(in: host).first { !$0.isActive && $0.visibleRect.contains($0.bounds) }
        let hovered = try #require(visible)
        let hoveredPosition = hovered.convert(hovered.bounds, to: host)
        let hoveredID = try #require(hovered.spaceID)
        await model.selectSpace(hoveredID)
        try await expectSpaceVisible(hoveredID, in: host)
        #expect(hovered.convert(hovered.bounds, to: host) == hoveredPosition)
        for index in [0, 10, 19] {
            await model.selectSpace(model.activeSpaces[index].id)
            try await expectSpaceVisible(model.activeSpaceID, in: host)
        }
        window.setContentSize(NSSize(width: 800, height: 46))
        await model.selectSpace(model.activeSpaces[10].id)
        try await expectSpaceVisible(model.activeSpaceID, in: host)
        window.setContentSize(NSSize(width: 220, height: 46))
        try await expectSpaceVisible(model.activeSpaceID, in: host)
    }

    private func expectSpaceVisible(_ id: WorkspaceSpace.ID?, in host: NSView) async throws {
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
            if let control = controls(in: host).first(where: { $0.spaceID == id && $0.isActive }),
               control.bounds.width >= 20, control.bounds.height == 28,
               control.visibleRect.contains(control.bounds) { return }
        }
        let selected = controls(in: host).first { $0.spaceID == id && $0.isActive }
        let control = try #require(selected)
        #expect(control.bounds.width >= 20)
        #expect(control.bounds.height == 28)
        #expect(control.visibleRect.contains(control.bounds))
    }

    @Test func crowdedSpacesRevealOnHoverWithoutMovingOrSelecting() async throws {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        for _ in 1..<6 { model.addSpace() }
        for (space, icon) in zip(model.activeSpaces, ["bolt.fill", "hammer.fill", "flame.fill", "person.2.fill", "book.fill", "globe"]) {
            model.setSpaceIcon(icon, for: space.id)
        }
        var selected = model.activeSpaceID
        let host = NSHostingView(rootView: SpaceSwitcherView(model: model)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 46),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let items = controls(in: host)
        #expect(items.count == 6)
        #expect(items.filter(\.showsIcon).map(\.spaceID) == [selected])
        for item in items {
            #expect(item.visibleRect.contains(item.bounds))
            // Native frames round each edge to a backing pixel.
            #expect(abs(item.bounds.width - 124.0 / 6) < 1)
        }
        let target = try #require(items.first)
        let frames = items.map { $0.convert($0.bounds, to: host) }
        for (left, right) in zip(frames, frames.dropFirst()) { #expect(left.maxX <= right.minX + 0.5) }
        try capture("compact", host: host)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        target.mouseEntered(with: event)
        items.last?.mouseExited(with: event)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(model.activeSpaceID == selected)
        #expect(items.filter(\.showsIcon).map(\.spaceID) == [target.spaceID, selected])
        #expect(items.filter(\.isActive).map(\.spaceID) == [selected])
        #expect(items.map { $0.convert($0.bounds, to: host) } == frames)
        try capture("hover", host: host)

        // Keyboard selection can move while the pointer still previews another Space.
        let nextID = try #require(items[2].spaceID)
        await model.selectSpace(nextID)
        selected = nextID
        try await expectSpaceVisible(selected, in: host)
        #expect(items.filter(\.showsIcon).map(\.spaceID) == [target.spaceID, selected])
        #expect(items.filter(\.isActive).map(\.spaceID) == [selected])
        #expect(items.map { $0.convert($0.bounds, to: host) } == frames)
        try capture("selection-during-hover", host: host)
        target.mouseExited(with: event)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(items.filter(\.showsIcon).map(\.spaceID) == [selected])
        target.mouseUp(with: event)
        try await expectSpaceVisible(target.spaceID, in: host)
        #expect(model.activeSpaceID == target.spaceID)
        #expect(target.accessibilityLabel() == model.activeSpaces.first?.name)
        // Tighten gaps and then targets before hiding icons. Six 24pt targets
        // still fit at 240pt (96pt is occupied by padding and the end buttons).
        for width in [360.0, 280, 240] {
            window.setContentSize(NSSize(width: width, height: 46))
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            #expect(items.allSatisfy { $0.showsIcon })
            #expect(items.allSatisfy { $0.visibleRect.contains($0.bounds) })
            #expect(items.allSatisfy { $0.bounds.width >= 24 })
            if width == 360 { #expect(items.allSatisfy { $0.bounds.width == 28 }) }
            try capture("expanded-\(Int(width))", host: host)
        }
        window.setContentSize(NSSize(width: 239, height: 46))
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(items.filter(\.showsIcon).map(\.spaceID) == [model.activeSpaceID])
    }

    private func capture(_ name: String, host: NSView) throws {
        guard let directory = ProcessInfo.processInfo.environment["MARPLE_SPACE_SNAPSHOT_DIR"] else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func controls(in view: NSView) -> [SpaceControlView.SpaceControl] {
        view.subviews.flatMap { child in
            (child as? SpaceControlView.SpaceControl).map { [$0] } ?? controls(in: child)
        }
    }
}
