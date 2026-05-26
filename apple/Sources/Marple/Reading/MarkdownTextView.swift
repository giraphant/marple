import SwiftUI
import AppKit
import MarpleKit

struct MarkdownTextView: NSViewRepresentable {
    let markdown: String
    let style: RenderStyle
    let scrollTarget: NSRange?
    /// Query whose matches are highlighted in the body (nil = none).
    var highlightQuery: String?
    /// One-shot scroll-to-match request (a clicked search line); nil = none.
    var jump: AppModel.MatchJump?
    let onLinkClick: (URL) -> Bool

    private static let matchColor = NSColor.controlAccentColor.withAlphaComponent(0.22)
    private static let currentMatchColor = NSColor.controlAccentColor.withAlphaComponent(0.45)

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

        // Search-match highlight: refresh when the doc or the query changes.
        let query = (highlightQuery?.isEmpty == false) ? highlightQuery : nil
        if markdown != co.lastHighlightMarkdown || query != co.lastHighlightQuery {
            applyHighlights(textView: textView, query: query, co: co)
            co.lastHighlightMarkdown = markdown
            co.lastHighlightQuery = query
            co.currentMatch = nil   // a re-highlight invalidates the current-match marker
        }

        // Scroll to a clicked match (one-shot, keyed by the jump's UUID).
        if let jump, jump.id != co.lastJumpID {
            co.lastJumpID = jump.id
            scrollToMatch(jump, in: scrollView, textView: textView, co: co)
        }
    }

    /// Apply a translucent background over every match of `query` in the rendered
    /// text via the layout manager's TEMPORARY attributes — so the permanent code /
    /// table backgrounds set by the renderer are untouched and clearing is a single
    /// range removal.
    private func applyHighlights(textView: NSTextView, query: String?, co: Coordinator) {
        guard let lm = textView.layoutManager, let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        guard let query else { co.matchRanges = []; return }
        let ranges = BodyMatching.ranges(in: storage.string, query: query)
        co.matchRanges = ranges
        for r in ranges {
            lm.addTemporaryAttribute(.backgroundColor, value: Self.matchColor, forCharacterRange: r)
        }
    }

    /// Resolve the clicked line's target range (anchor first, ordinal fallback),
    /// scroll it to a comfortable position near the top, and mark it as current.
    private func scrollToMatch(_ jump: AppModel.MatchJump, in scrollView: NSScrollView,
                               textView: NSTextView, co: Coordinator) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage else { return }
        guard let target = BodyMatching.resolveJumpTarget(
            in: storage.string, matchRanges: co.matchRanges,
            anchor: jump.anchor, ordinal: jump.ordinal) else { return }

        // Restore the previous current-match to the normal color, promote the new one.
        if let prev = co.currentMatch {
            lm.addTemporaryAttribute(.backgroundColor, value: Self.matchColor, forCharacterRange: prev)
        }
        lm.addTemporaryAttribute(.backgroundColor, value: Self.currentMatchColor, forCharacterRange: target)
        co.currentMatch = target

        lm.ensureLayout(for: tc)
        let glyphRange = lm.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let clip = scrollView.contentView
        let topPadding: CGFloat = 96
        let docY = rect.minY + textView.textContainerOrigin.y
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let y = min(max(0, docY - topPadding), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        co.lastScrollTarget = target   // keep the outline channel from re-scrolling
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

        // Search-match highlight state.
        var lastHighlightQuery: String?
        var lastHighlightMarkdown: String = ""
        var matchRanges: [NSRange] = []
        var currentMatch: NSRange?
        var lastJumpID: UUID?

        init(onLinkClick: @escaping (URL) -> Bool) {
            self.onLinkClick = onLinkClick
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            return onLinkClick(url)
        }
    }
}
