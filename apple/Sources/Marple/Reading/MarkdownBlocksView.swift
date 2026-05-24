import SwiftUI
import MarpleKit

/// Custom URL scheme that lets wikilinks live as tappable `.link` runs inside a
/// wrapping `Text(AttributedString)` and be intercepted via `OpenURLAction`.
enum WikiURL {
    static let scheme = "marple"
    static func make(_ target: String) -> URL? {
        let enc = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        return URL(string: "\(scheme)://wiki/\(enc)")
    }
    static func target(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let p = url.path
        return p.hasPrefix("/") ? String(p.dropFirst()) : p
    }
}

/// Flatten inline tokens into one AttributedString so the text wraps naturally;
/// wikilinks become accent-colored `.link` runs (tapped via the openURL action).
func attributedInline(_ tokens: [InlineToken]) -> AttributedString {
    var out = AttributedString()
    for token in tokens {
        switch token {
        case .text(let s):
            out += AttributedString(s)
        case .wikilink(let target, let label):
            var run = AttributedString(label)
            run.foregroundColor = .accentColor
            run.underlineStyle = .single
            if let url = WikiURL.make(target) { run.link = url }
            out += run
        }
    }
    return out
}

struct BlockView: View {
    let block: RenderBlock
    @Environment(\.readingFont) private var readingFont

    var body: some View {
        switch block {
        case .heading(let level, let tokens):
            Text(attributedInline(tokens))
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let tokens):
            Text(attributedInline(tokens))
                .font(readingFont.bodyFont)
                .lineSpacing(readingFont.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: Space.s2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                        Text("•")
                        Text(attributedInline(item))
                            .lineSpacing(readingFont.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(readingFont.bodyFont)
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: Space.s2) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                        Text("\(idx + 1).")
                        Text(attributedInline(item))
                            .lineSpacing(readingFont.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(readingFont.bodyFont)
        case .quote(let tokens):
            Text(attributedInline(tokens))
                .font(readingFont.bodyFont)
                .lineSpacing(readingFont.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .padding(.leading, Space.s5)
                .overlay(alignment: .leading) {
                    Rectangle().frame(width: 3).foregroundStyle(.secondary)
                }
        case .codeBlock(_, let code):
            Text(code)
                .font(.system(.body, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .thematicBreak:
            Divider().padding(.vertical, Space.s4)
        case .table(let headers, let rows):
            TableView(headers: headers, rows: rows)
        }
    }
    func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return Typo.display
        case 2: return Typo.title
        case 3: return Typo.title3
        default: return Typo.headline
        }
    }
}

private struct TableView: View {
    let headers: [[InlineToken]]
    let rows: [[[InlineToken]]]
    @Environment(\.readingFont) private var readingFont

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, cellTokens in
                        Text(attributedInline(cellTokens))
                            .font(Typo.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.s5)
                            .padding(.vertical, Space.s4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(.quaternary)

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cellTokens in
                            Text(attributedInline(cellTokens))
                                .font(readingFont.bodyFont)
                                .lineSpacing(readingFont.lineSpacing)
                                .padding(.horizontal, Space.s5)
                                .padding(.vertical, Space.s4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
