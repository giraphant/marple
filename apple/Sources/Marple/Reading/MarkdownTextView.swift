import SwiftUI
import AppKit
import MarpleKit

struct MarkdownTextView: NSViewRepresentable {
    let markdown: String
    let style: RenderStyle
    let scrollTarget: NSRange?
    let onLinkClick: (URL) -> Bool

    private final class MarkdownScrollView: NSScrollView {
        override func layout() {
            super.layout()
            MarkdownTextView.sizeDocumentView(in: self)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLinkClick: onLinkClick)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: Reading.measure, height: .greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        textContainer.lineBreakMode = .byWordWrapping

        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: Space.s9)
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let co = context.coordinator

        if markdown != co.lastMarkdown || style != co.lastStyle {
            let rendered = MarkdownRenderer.render(markdown, style: style)
            textView.textStorage?.setAttributedString(rendered.attributedString)
            co.lastMarkdown = markdown
            co.lastStyle = style
            co.headings = rendered.headings
        }

        Self.sizeDocumentView(in: scrollView)

        if let target = scrollTarget, target != co.lastScrollTarget {
            textView.scrollRangeToVisible(target)
            co.lastScrollTarget = target
        }
    }

    private static func sizeDocumentView(in scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer else { return }

        let availableWidth = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : Reading.measure
        let sidePadding = Space.s10
        let columnWidth = min(Reading.measure, max(0, availableWidth - sidePadding * 2))
        let horizontalInset = max(sidePadding, (availableWidth - columnWidth) / 2)
        textView.textContainerInset = NSSize(width: horizontalInset, height: Space.s9)
        tc.containerSize = NSSize(width: columnWidth, height: .greatestFiniteMagnitude)

        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let height = ceil(used.maxY + textView.textContainerInset.height * 2)
        let size = NSSize(width: availableWidth, height: height)
        if textView.frame.size != size {
            textView.setFrameSize(size)
        }
    }

    // MARK: Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        let onLinkClick: (URL) -> Bool
        weak var textView: NSTextView?

        var lastMarkdown: String = ""
        var lastStyle: RenderStyle?
        var lastScrollTarget: NSRange?
        var headings: [HeadingAnchor] = []

        init(onLinkClick: @escaping (URL) -> Bool) {
            self.onLinkClick = onLinkClick
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            return onLinkClick(url)
        }
    }
}
