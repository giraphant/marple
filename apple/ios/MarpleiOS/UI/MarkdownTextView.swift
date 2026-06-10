import SwiftUI
import UIKit
import MarpleKit

/// Displays a rendered markdown `NSAttributedString` in a read-only UITextView,
/// mirroring the Mac's NSTextView-based MarkdownTextView.
///
/// `scrollTarget` + `scrollNonce` drive jump-to-section from the outline: each
/// outline tap bumps the nonce so the same heading can be jumped to repeatedly.
struct MarkdownTextView: UIViewRepresentable {
    let attributed: NSAttributedString
    var scrollTarget: NSRange? = nil
    var scrollNonce: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 96, right: 16)
        tv.alwaysBounceVertical = true
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.attributedText != attributed { tv.attributedText = attributed }

        // Jump to a heading only when the outline fires a new request (nonce bump),
        // so re-rendering (e.g. a font-size change) never yanks the scroll position.
        guard scrollNonce != context.coordinator.lastNonce else { return }
        context.coordinator.lastNonce = scrollNonce
        guard let range = scrollTarget, range.location != NSNotFound else { return }
        // TextKit 2 throughout — touching `tv.layoutManager` would fall the view back
        // to TextKit 1 and silently disable the table attachment views.
        guard let layoutManager = tv.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let documentStart = layoutManager.documentRange.location
        guard let start = contentManager.location(documentStart, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length),
              let target = NSTextRange(location: start, end: end) else { return }
        // Lay out up to the target so its segment frame (and contentSize) is real.
        if let upToTarget = NSTextRange(location: documentStart, end: end) {
            layoutManager.ensureLayout(for: upToTarget)
        }
        var headingMinY: CGFloat?
        layoutManager.enumerateTextSegments(in: target, type: .standard,
                                            options: [.rangeNotRequired]) { _, frame, _, _ in
            headingMinY = frame.minY
            return false
        }
        guard let minY = headingMinY else { return }
        // Place the heading near the top rather than just "barely visible".
        let maxY = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
        let y = min(max(0, minY - tv.textContainerInset.top + 8), maxY)
        tv.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    final class Coordinator {
        var lastNonce = 0
    }
}
