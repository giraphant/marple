import AppKit
import SwiftUI

/// Floating command-palette window. Mirrors CodeEdit's `SearchPanel`: a titled,
/// transparent-titlebar `NSPanel` that becomes key — which is the reliable native
/// fix for "the search field doesn't get focus." A SwiftUI `.overlay` inside the
/// main window can't take first responder cleanly; a key panel makes the hosted
/// `TextField` first responder automatically. App switching preserves the search;
/// clicking another window in Marple dismisses it.
final class CommandPalettePanel: NSPanel {
    private var outsideClickMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 60),
            styleMask: [.fullSizeContentView, .titled, .resizable],
            backing: .buffered, defer: false
        )
        hidesOnDeactivate = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        // Transparent window so any area beyond the rounded content card is
        // see-through (no white box when the window is taller than the content);
        // the SwiftUI view draws its own rounded material card.
        isOpaque = false
        backgroundColor = .clear
        // The default panel fade-in/out is the perceived lag on both ⌘T-open and
        // Esc-close; disabling it makes the palette feel instant (Maccy uses .none,
        // CotEditor .utilityWindow for the same reason).
        animationBehavior = .none
        center()
        // Resigning key also happens on app switches and automatic focus
        // restoration. Only an explicit in-app outside click dismisses search.
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if let self, let window = event.window, window !== self { self.close() }
            return event
        }
    }

    override var canBecomeKey: Bool { true }

    override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? {
        let button = super.standardWindowButton(b)
        button?.isHidden = true
        return button
    }

    override func close() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        super.close()
    }
}

/// Owns the single command-palette panel and toggles it (⌘T). Resumes an open
/// search after app switching; only a dismissed search gets a fresh view.
@MainActor
enum CommandPalettePresenter {
    private static var panel: CommandPalettePanel?

    static func toggle(model: AppModel) {
        if let panel, panel.isVisible {
            if NSApp.isActive && panel.isKeyWindow {
                panel.close()
                Self.panel = nil
            } else {
                if !NSApp.isActive { NSApp.activate() }
                panel.makeKeyAndOrderFront(nil)
            }
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
        // Only activate when the app isn't already frontmost (e.g. ⌘T from the menu
        // while inactive) — the common in-app ⌘T path is already active, so skipping
        // the activate avoids its window-reorder latency. An active app's key panel
        // still lands focus via the onAppear nudge.
        if !NSApp.isActive { NSApp.activate() }
        panel.makeKeyAndOrderFront(nil)
        Self.panel = panel
    }
}
