import AppKit
import SwiftUI

/// Floating command-palette window. Mirrors CodeEdit's `SearchPanel`: a titled,
/// transparent-titlebar `NSPanel` that becomes key — which is the reliable native
/// fix for "the search field doesn't get focus." A SwiftUI `.overlay` inside the
/// main window can't take first responder cleanly; a key panel makes the hosted
/// `TextField` first responder automatically. Closes itself when it loses key.
final class CommandPalettePanel: NSPanel, NSWindowDelegate {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 60),
            styleMask: [.fullSizeContentView, .titled, .resizable],
            backing: .buffered, defer: false
        )
        delegate = self
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        // Transparent window so any area beyond the rounded content card is
        // see-through (no white box when the window is taller than the content);
        // the SwiftUI view draws its own rounded material card.
        isOpaque = false
        backgroundColor = .clear
        center()
    }

    override var canBecomeKey: Bool { true }

    override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? {
        let button = super.standardWindowButton(b)
        button?.isHidden = true
        return button
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

/// Owns the single command-palette panel and toggles it (⌘T). Recreates the
/// hosted SwiftUI view on each open so the query/mode reset to a fresh state.
@MainActor
enum CommandPalettePresenter {
    private static var panel: CommandPalettePanel?

    static func toggle(model: AppModel) {
        if let panel, panel.isKeyWindow {
            panel.close()
            Self.panel = nil
            return
        }
        open(model: model)
    }

    private static func open(model: AppModel) {
        panel?.close()
        // A SwiftUI-lifecycle app isn't guaranteed active when ⌘T fires from a
        // menu command; a non-active app's panel won't become key, and a non-key
        // window never auto-selects a first responder. Activating first is the
        // step a document/AppKit app gets for free (this is why CodeEdit needs no
        // focus code). With the panel key, `defaultFocus` lands the search field.
        // Present as a standalone floating panel — NOT a child window. A child
        // window does not reliably become key, and a non-key window silently
        // no-ops every focus attempt (@FocusState, defaultFocus, makeFirstResponder
        // all). Maccy/CotEditor present their command panels standalone for exactly
        // this reason.
        let panel = CommandPalettePanel()
        let root = CommandPalette(model: model) { [weak panel] in panel?.close() }
        panel.contentView = NSHostingView(rootView: root)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Self.panel = panel
    }
}
