import Foundation

public struct OutlineItem: Equatable, Sendable, Identifiable {
    public let blockIndex: Int   // index into the rendered [RenderBlock]; scroll target + id
    public let level: Int        // 1–6
    public let text: String
    public var id: Int { blockIndex }
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
public func outline(from blocks: [RenderBlock]) -> [OutlineItem] {
    var out: [OutlineItem] = []
    for (i, block) in blocks.enumerated() {
        if case let .heading(level, tokens) = block {
            let text = tokensText(tokens).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                out.append(OutlineItem(blockIndex: i, level: level, text: text))
            }
        }
    }
    return out
}
