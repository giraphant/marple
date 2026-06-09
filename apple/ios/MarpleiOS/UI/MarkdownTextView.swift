import SwiftUI
import UIKit
import MarpleKit

/// Displays a rendered markdown `NSAttributedString` in a read-only UITextView,
/// mirroring the Mac's NSTextView-based MarkdownTextView.
struct MarkdownTextView: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        tv.alwaysBounceVertical = true
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.attributedText = attributed
    }
}
