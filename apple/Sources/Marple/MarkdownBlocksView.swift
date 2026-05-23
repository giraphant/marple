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
    var body: some View {
        switch block {
        case .heading(let level, let tokens):
            Text(attributedInline(tokens))
                .font(headingFont(level)).bold()
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let tokens):
            Text(attributedInline(tokens))
                .fixedSize(horizontal: false, vertical: true)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(attributedInline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).")
                        Text(attributedInline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let tokens):
            Text(attributedInline(tokens))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().frame(width: 3).foregroundStyle(.secondary)
                }
        case .codeBlock(_, let code):
            Text(code)
                .font(.system(.body, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
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
