import SwiftUI
import MarpleKit

/// Wrapping layout for inline runs (text + tappable wikilinks).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = (maxWidth == .infinity) ? x : maxWidth
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Renders inline tokens: plain-text runs + tappable wikilink buttons.
struct InlineFlow: View {
    let tokens: [InlineToken]
    let onFollow: (String) -> Void
    var body: some View {
        FlowLayout {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .text(let s):
                    Text(s)
                case .wikilink(let target, let label):
                    Button(label) { onFollow(target) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

struct BlockView: View {
    let block: RenderBlock
    let onFollow: (String) -> Void
    var body: some View {
        switch block {
        case .heading(let level, let tokens):
            InlineFlow(tokens: tokens, onFollow: onFollow)
                .font(headingFont(level)).bold().padding(.top, 8)
        case .paragraph(let tokens):
            InlineFlow(tokens: tokens, onFollow: onFollow)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        InlineFlow(tokens: items[i], onFollow: onFollow)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1).")
                        InlineFlow(tokens: items[i], onFollow: onFollow)
                    }
                }
            }
        case .quote(let tokens):
            InlineFlow(tokens: tokens, onFollow: onFollow)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().frame(width: 3).foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
        case .codeBlock(_, let code):
            Text(code)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .thematicBreak:
            Divider().padding(.vertical, 8)
        }
    }
    func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }
}
