import Foundation

public struct OutlineItem: Equatable, Sendable, Identifiable {
    public let blockIndex: Int   // index into the rendered [RenderBlock]; scroll target + id
    public let level: Int        // 1–6
    public let text: String
    public let characterRange: NSRange?  // character range in NSAttributedString (for scrollRangeToVisible)
    public var id: Int { blockIndex }

    public init(blockIndex: Int, level: Int, text: String, characterRange: NSRange? = nil) {
        self.blockIndex = blockIndex
        self.level = level
        self.text = text
        self.characterRange = characterRange
    }
}

/// Visible text of an inline-token run (wikilinks render as their label).
public func tokensText(_ tokens: [InlineToken]) -> String {
    tokens.map { token in
        switch token {
        case .text(let s):                return s
        case .wikilink(_, let label):     return label
        }
    }.joined()
}

/// Heading outline derived from already-parsed blocks. Code-block content is its
/// own `RenderBlock`, so a `#` inside a fence can't be mistaken for a heading.
/// The first H1 is dropped — it's the document's own title (redundant in the
/// outline sidebar since the user is already viewing that document).
public func outline(from blocks: [RenderBlock]) -> [OutlineItem] {
    var out: [OutlineItem] = []
    var firstH1Skipped = false
    for (i, block) in blocks.enumerated() {
        if case let .heading(level, tokens) = block {
            let text = tokensText(tokens).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if !firstH1Skipped && level == 1 {
                firstH1Skipped = true
                continue
            }
            out.append(OutlineItem(blockIndex: i, level: level, text: text))
        }
    }
    return out
}

/// Build outline from heading anchors produced by MarkdownRenderer. Filters
/// identically to the block-based variant (drop empty-text headings, then drop
/// the first H1 title) so the two produce the same heading ordinal sequence —
/// the Mac reader bridges the font-free outline (no ranges) to this one (with
/// ranges, from the live text view) by that ordinal.
public func outline(from headings: [HeadingAnchor]) -> [OutlineItem] {
    var out: [OutlineItem] = []
    var firstH1Skipped = false
    var idx = 0
    for heading in headings {
        let text = heading.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        if !firstH1Skipped && heading.level == 1 {
            firstH1Skipped = true
            continue
        }
        out.append(OutlineItem(
            blockIndex: idx,
            level: heading.level,
            text: text,
            characterRange: heading.range
        ))
        idx += 1
    }
    return out
}
