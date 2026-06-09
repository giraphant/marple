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
        guard let range = scrollTarget, range.location != NSNotFound,
              range.location <= tv.textStorage.length else { return }
        // Place the heading near the top rather than just "barely visible".
        let glyphRange = tv.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = tv.layoutManager.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
        let maxY = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
        let y = min(max(0, rect.minY - tv.textContainerInset.top + 8), maxY)
        tv.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    final class Coordinator {
        var lastNonce = 0
    }
}
