import AppKit
import SwiftUI
import MarpleKit

/// Holds the booted model for app-wide menu commands. Marple is single-window, and
/// an AppKit-owned window isn't reached by SwiftUI's `@FocusedValue`, so a global
/// reference replaces it (see TabCommands).
@MainActor enum ActiveModel { static var current: AppModel? }

/// Owns the main `NSWindow` (AppKit, like Notes / Mail / CodeEdit) so the
/// `NSSplitViewController` can be the window's `contentViewController`. The content
/// swaps through setup → progress → the split shell as the app boots.
@MainActor
final class MarpleWindowController: NSWindowController, NSWindowDelegate {
    private let appState = AppState()
    private let toolbarController = MarpleToolbarController()
    private let sidebarUndoManager = UndoManager()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 960, height: 600)   // fit sidebar + list + reader at min
        window.setFrameAutosaveName("MarpleMainWindow")
        self.init(window: window)
        window.delegate = self
    }

    func start() {
        let restored = window?.setFrameUsingName("MarpleMainWindow") ?? false
        route()
        // Use the user's saved frame if it's valid; otherwise a screen-relative default
        // (so it's generous on big displays and still fits small laptops).
        if let window, !restored || window.frame.width < 960 || window.frame.height < 600 {
            window.setFrame(Self.defaultFrame(for: window), display: false)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        sidebarUndoManager
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

    private func route() {
        let root = UserDefaults.standard.string(forKey: "marple.workspaceRoot") ?? ""
        guard !root.isEmpty, let ws = try? resolveWorkspace(pickedPath: root) else {
            setContent(boxed(SetupView { [weak self] picked in
                UserDefaults.standard.set(picked, forKey: "marple.workspaceRoot")
                self?.route()
            }))
            return
        }
        boot(paths: VaultPaths(workspaceRoot: ws.workspaceRoot, vaultDir: ws.vaultDir))
    }

    private func boot(paths: VaultPaths) {
        // QUA-105: `AppState.boot` is now synchronous (no awaits inside, the
        // data load is dispatched onto a background Task internally). We mount
        // the split chrome immediately so it's the window's content when
        // `showWindow` is called below — no "ProgressView for several seconds"
        // wait, no spinner→split-swap flash. Views render with
        // `model.isBootstrapping=true` and show skeleton state until the
        // first loadIndex completes.
        appState.boot(paths: paths)
        guard let model = appState.model else {
            if let err = appState.bootError {
                setContent(boxed(
                    ContentUnavailableView("启动失败", systemImage: "exclamationmark.triangle",
                                           description: Text(err))))
            }
            return
        }
        sidebarUndoManager.removeAllActions()
        model.undoManager = sidebarUndoManager
        ActiveModel.current = model
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
