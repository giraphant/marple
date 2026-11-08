import AppKit
import SwiftUI
import MarpleKit

/// Routes app-wide menu commands to a window. AppKit-owned windows aren't reached
/// by SwiftUI's `@FocusedValue`, so commands ask here (see TabCommands). The target
/// is the front-most main window, computed from AppKit's window order like
/// NetNewsWire — Settings and panels never count.
@MainActor enum ActiveModel {
    /// Open main windows, kept by the app delegate.
    static var controllers: [MarpleWindowController] = []

    static var current: AppModel? { orderedControllers.lazy.compactMap(\.model).first }

    /// Main windows, front first.
    static var orderedControllers: [MarpleWindowController] {
        let order = Dictionary(NSApp.orderedWindows.enumerated().map { (ObjectIdentifier($0.element), $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        return controllers.enumerated().sorted { a, b in
            let ra = a.element.window.flatMap { order[ObjectIdentifier($0)] } ?? Int.max
            let rb = b.element.window.flatMap { order[ObjectIdentifier($0)] } ?? Int.max
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }
}

/// Owns one main `NSWindow` (AppKit, like Notes / Mail / CodeEdit) so the
/// `NSSplitViewController` can be the window's `contentViewController`. The content
/// is the setup view until a vault is chosen, then the split shell over one
/// `AppModel` (this window's session on the shared `Library`).
@MainActor
final class MarpleWindowController: NSWindowController, NSWindowDelegate {
    private let toolbarController = MarpleToolbarController()
    private(set) var model: AppModel?
    /// Called once the window has closed (not when the app quits with it open).
    var onClose: ((MarpleWindowController) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 960, height: 600)   // fit sidebar + list + reader at min
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
    }

    /// First-run: pick the vault folder in this window.
    func showSetup(onPicked: @escaping (String) -> Void) {
        placeWindow(frame: nil, cascadeFrom: nil)
        setContent(boxed(SetupView(onPicked: onPicked)))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showBootError(_ message: String) {
        setContent(boxed(ContentUnavailableView("启动失败", systemImage: "exclamationmark.triangle",
                                                description: Text(message))))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Mount the split shell for `model`, placed at its saved frame or cascaded
    /// from `cascadeFrom` (the window it was opened from).
    func show(_ model: AppModel, cascadeFrom source: NSWindow?) {
        self.model = model
        placeWindow(frame: model.windowFrame, cascadeFrom: source)
        model.undoManager = model.library.undoManager
        applyTheme()
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = false
        window?.toolbarStyle = .unified
        let split = MarpleSplitViewController(model: model)
        setContent(split)
        toolbarController.model = model
        toolbarController.shell = split
        toolbarController.splitView = split.splitView   // we own this split → tracking separators are safe
        window?.toolbar = toolbarController.makeToolbar()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        rememberFrame()
        trackTitle()
    }

    /// Keep the (hidden) window title current: it names this window in the Dock
    /// menu, the Window menu and Mission Control.
    private func trackTitle() {
        guard let model else { return }
        let title = withObservationTracking { model.windowTitle } onChange: { [weak self] in
            Task { @MainActor in self?.trackTitle() }
        }
        if window?.title != title { window?.title = title }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model?.library.undoManager
    }

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    private func rememberFrame() {
        // Full screen would replace the windowed frame with the screen's.
        guard let window, let model, !window.styleMask.contains(.fullScreen) else { return }
        model.windowFrame = window.frameDescriptor
    }

    private func placeWindow(frame descriptor: String?, cascadeFrom source: NSWindow?) {
        guard let window else { return }
        if let descriptor {
            // Put the window back exactly where it was while that spot is still on
            // a screen; `setFrame(from:)` alone re-homes it onto the main screen,
            // which piles every window onto one display.
            let numbers = descriptor.split(separator: " ").compactMap { Double($0) }
            let saved = numbers.count >= 4
                ? NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) : .zero
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
                window.setFrame(saved, display: false)
            } else {
                window.setFrame(from: descriptor)
            }
        } else if let source {
            window.setFrame(source.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: source.frame.minX,
                                                                            y: source.frame.maxY)))
        } else if !window.setFrameUsingName("MarpleMainWindow") {
            // The single-window build's saved frame seeds the first window.
            window.setFrame(Self.defaultFrame(for: window), display: false)
        }
        // Use the saved frame only while it's valid; otherwise a screen-relative
        // default (generous on big displays, still fits small laptops).
        if window.frame.width < 960 || window.frame.height < 600
            || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.setFrame(Self.defaultFrame(for: window), display: false)
        }
    }

    private static func defaultFrame(for window: NSWindow) -> NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(visible.width * 0.88, 960), 1800)
        let height = min(max(visible.height * 0.90, 600), 1150)
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                      width: width, height: height)
    }

    private func setContent(_ vc: NSViewController) {
        // Restore the frame after swapping: an NSSplitViewController (and hosting
        // controllers) resize the window to their fitting size on assignment, which
        // shrank the window once the split loaded. CodeEdit does the same (setFrame
        // after contentViewController).
        let frame = window?.frame
        contentViewController = vc
        if let window, let frame { window.setFrame(frame, display: true) }
    }

    /// Hosting controller that does NOT drive the window size — by default an
    /// `NSHostingController` resizes the window to its content's fitting size, which
    /// shrank the window to the boot spinner. `sizingOptions = []` makes it fill instead.
    private func boxed<V: View>(_ view: V) -> NSHostingController<V> {
        let hc = NSHostingController(rootView: view)
        hc.sizingOptions = []
        return hc
    }

    private func applyTheme() {
        let pref = UserDefaults.standard.string(forKey: SettingsKeys.theme)
            .flatMap(ThemePreference.init(rawValue:)) ?? .system
        window?.appearance = switch pref {
        case .light: NSAppearance(named: .aqua)
        case .dark:  NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}
