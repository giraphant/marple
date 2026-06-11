import SwiftUI
import AppKit
import MarpleKit

struct MarkdownTextView: NSViewRepresentable {
    let markdown: String
    let style: RenderStyle
    /// Identity of the open document (its path). Drives per-doc scroll memory:
    /// switching to a different id restores that doc's remembered offset.
    let documentID: String
    /// Heading ordinal to scroll to (index into the open doc's outline), or nil.
    /// The outline is built font-free in Catalog, so the actual character range is
    /// resolved here from the live render's heading anchors (QUA-227).
    let scrollTargetOrdinal: Int?
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

        // On scroll, NSClipView only invalidates the newly-revealed strip (since
        // macOS 11 this minimization is forced and `copiesOnScroll` is a no-op). That
        // strip-only repaint intermittently left table cells (custom NSTextBlock
        // drawing) blank until a selection forced a redraw. Force a full redraw of the
        // visible document on every scroll, as Apple's docs recommend.
        override func reflectScrolledClipView(_ cView: NSClipView) {
            super.reflectScrolledClipView(cView)
            if let doc = documentView { doc.setNeedsDisplay(doc.visibleRect) }
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
        // Force contiguous layout. With the default (non-contiguous) layout, TextKit
        // lays out regions lazily and a custom table block can stay un-rendered until
        // selection forces a re-layout — the intermittent blank-cell dropout.
        layoutManager.allowsNonContiguousLayout = false
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
        // Own the documentView frame ourselves via `sizeDocumentView` — leaving
        // `isVerticallyResizable = true` had NSTextView's own auto-resize race with
        // our manual `setFrameSize`, intermittently leaving the frame ≈ viewport
        // height so NSScrollView decided nothing was scrollable (wheel + outline
        // jump both dead, content still painted because glyphs were laid out for
        // the full container).
        textView.isVerticallyResizable = false
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

        let contentChanged = markdown != co.lastMarkdown
        // A doc switch is a content change to a *different* identity. (A same-id
        // content change is an FSEvents reload — keep the reader where it was.)
        let docSwitched = contentChanged && documentID != co.currentDocID

        // QUA-151: before swapping in the new body, remember the outgoing doc's
        // scroll position (the old content is still displayed, so the clip offset
        // is still its own). Restored when we switch back to it.
        if docSwitched, let outgoing = co.currentDocID {
            co.scrollOffsets[outgoing] = scrollView.contentView.bounds.origin.y
        }

        if contentChanged || style != co.lastStyle {
            let rendered = MarkdownRenderer.render(markdown, style: style)
            textView.textStorage?.setAttributedString(rendered.attributedString)
            co.lastMarkdown = markdown
            co.lastStyle = style
            co.headings = rendered.headings
        }
        if contentChanged { co.currentDocID = documentID }

        Self.sizeDocumentView(in: scrollView)

        let hasPendingJump = jump != nil && jump?.id != co.lastJumpID
        // Map the heading ordinal to a character range via the live render's anchors
        // (outline(from:) filters identically to the font-free outline in Catalog,
        // so ordinals line up). co.headings was refreshed above on any content change.
        let target: NSRange? = scrollTargetOrdinal.flatMap { ord in
            let items = outline(from: co.headings)
            return items.indices.contains(ord) ? items[ord].characterRange : nil
        }
        if let target, target != co.lastScrollTarget {
            textView.scrollRangeToVisible(target)
            co.lastScrollTarget = target
        } else if Self.shouldRepositionOnDocSwitch(docSwitched: docSwitched,
                                                   hasScrollTarget: target != nil,
                                                   hasPendingJump: hasPendingJump) {
            // No explicit target/jump: restore this doc's remembered offset, else
            // open at the top. (NSScrollView keeps the previous doc's clip offset
            // across setAttributedString — without this the new doc would "drift"
            // to the old pixel position.)
            co.lastScrollTarget = nil
            Self.scroll(scrollView, toY: co.scrollOffsets[documentID] ?? 0)
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

    /// Whether a render pass owns repositioning the reader for a document switch
    /// (restore remembered offset, else top). True only when the body switched to a
    /// different document AND nothing else wants to drive the scroll (an outline
    /// target or a one-shot search jump both take precedence).
    nonisolated static func shouldRepositionOnDocSwitch(docSwitched: Bool,
                                                        hasScrollTarget: Bool,
                                                        hasPendingJump: Bool) -> Bool {
        docSwitched && !hasScrollTarget && !hasPendingJump
    }

    /// Scroll the clip view to `y`, clamped to the scrollable range.
    private static func scroll(_ scrollView: NSScrollView, toY y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        let clamped = min(max(0, y), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(clip)
    }

    private static func sizeDocumentView(in scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer,
              let storage = textView.textStorage else { return }

        let availableWidth = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : Reading.measure
        let sidePadding = Space.s10
        let columnWidth = min(Reading.measure, max(0, availableWidth - sidePadding * 2))
        let horizontalInset = max(sidePadding, (availableWidth - columnWidth) / 2)
        textView.textContainerInset = NSSize(width: horizontalInset, height: Space.s9)
        tc.containerSize = NSSize(width: columnWidth, height: .greatestFiniteMagnitude)

        // `ensureLayout(for: container)` lays out only until the container fills, which
        // with `.greatestFiniteMagnitude` height should be everything — but the layout
        // manager can still return a stale `usedRect` if glyph generation hasn't
        // caught up with the latest textStorage edit. Forcing layout by character
        // range over the whole storage is deterministic.
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: storage.length))
        let used = lm.usedRect(for: tc)
        let height = ceil(used.maxY + textView.textContainerInset.height * 2)
        let size = NSSize(width: availableWidth, height: height)
        if textView.frame.size != size {
            textView.setFrameSize(size)
            // Nudge the scroll view to recompute its scrollable range. Without this
            // it occasionally kept believing the document was unscrollable (held the
            // previous "frame ≈ viewport" geometry) even after we grew the frame.
            scrollView.reflectScrolledClipView(scrollView.contentView)
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

        // Per-document scroll memory (QUA-151). `currentDocID` is the doc currently
        // installed in the text view; `scrollOffsets` remembers each visited doc's
        // last clip offset so switching back restores it instead of drifting/resetting.
        var currentDocID: String?
        var scrollOffsets: [String: CGFloat] = [:]

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
            // The renderer stores `.link` as a String (Link.destination), so the
            // delegate may receive either an NSURL or an NSString depending on
            // AppKit's coercion. Accept both so wikilink and `marple://seek`
            // clicks reliably reach `onLinkClick`.
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            return onLinkClick(url)
        }
    }
}
