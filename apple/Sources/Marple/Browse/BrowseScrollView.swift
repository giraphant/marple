import AppKit

/// SwiftUI replaces the native browser when its presentation changes. AppKit
/// then falls back to the window as first responder; give an unclaimed focus
/// back to the new table/collection, without taking it from an editor or reader.
final class BrowseScrollView: NSScrollView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.isHiddenOrHasHiddenAncestor,
                  window.firstResponder == nil || window.firstResponder === window,
                  let documentView = self.documentView else { return }
            window.makeFirstResponder(documentView)
        }
    }
}
