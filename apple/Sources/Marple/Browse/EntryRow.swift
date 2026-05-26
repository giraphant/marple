import SwiftUI
import MarpleKit

/// List-row anatomy (spec §4): title + content preview + a calm meta line.
/// The preview's natural height variation is the "how much is here" signal —
/// replacing the old gold-star wall. In search mode the row also lists the body
/// lines that matched (Bear/Ulysses style), each clickable to jump into the doc.
struct EntryRow: View {
    let entry: Entry

    // Search-mode extras (plain data passed down by EntryListView, so the row never
    // observes AppModel broadly — keeps per-keystroke field edits cheap).
    var matches: BodyMatches? = nil
    var expanded: Bool = false
    var onToggleExpand: (() -> Void)? = nil
    var onMatchTap: ((BodyMatchLine) -> Void)? = nil

    private let matchCap = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(entry.title ?? "(untitled)")
                .font(Typo.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if !entry.preview.isEmpty {
                Text(entry.preview)
                    .font(Typo.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(hasMatches ? 2 : 3)
            }

            if hasMeta {
                HStack(spacing: Space.s3) {
                    if let meta = metaLeading {
                        Text(meta).lineLimit(1)
                    }
                    Spacer(minLength: Space.s2)
                    if entry.ratingScore > 0 {
                        HStack(spacing: Space.s1) {
                            Image(systemName: "star.fill")
                            Text(ratingText).monospacedDigit()
                        }
                    }
                    if entry.hasPDF {
                        Image(systemName: "doc.richtext")
                    }
                }
                .font(Typo.caption)
                .foregroundStyle(.tertiary)
            }

            matchedLines
        }
        .padding(.vertical, Space.s5)
        .tag(entry.path)
    }

    private var hasMatches: Bool { (matches?.lines.isEmpty == false) }

    @ViewBuilder private var matchedLines: some View {
        if let matches, !matches.lines.isEmpty {
            let shown = expanded ? matches.lines : Array(matches.lines.prefix(matchCap))
            VStack(alignment: .leading, spacing: Space.s2) {
                ForEach(shown) { line in
                    Button { onMatchTap?(line) } label: {
                        Text(highlighted(line))
                            .font(Typo.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("跳转到这一处")
                }
                if matches.lines.count > matchCap {
                    Button { onToggleExpand?() } label: {
                        Text(expanded ? "收起" : "再显示 \(matches.lines.count - matchCap) 个匹配项…")
                            .font(Typo.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, Space.s2)
        }
    }

    /// Build the matched-line text with the keyword spans tinted in the accent color.
    private func highlighted(_ line: BodyMatchLine) -> AttributedString {
        var astr = AttributedString(line.excerpt)
        astr.foregroundColor = .secondary
        let excerpt = line.excerpt
        for span in line.spans {
            let nsr = NSRange(location: span.location, length: span.length)
            guard let r = Range(nsr, in: excerpt),
                  let lo = AttributedString.Index(r.lowerBound, within: astr),
                  let hi = AttributedString.Index(r.upperBound, within: astr) else { continue }
            astr[lo..<hi].backgroundColor = Color.accentColor.opacity(0.22)
            astr[lo..<hi].foregroundColor = Color.accentColor
        }
        return astr
    }

    private var metaLeading: String? {
        var parts: [String] = []
        if !entry.author.isEmpty { parts.append(entry.author.joined(separator: ", ")) }
        if let y = entry.year, !y.isEmpty { parts.append(y) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var hasMeta: Bool {
        metaLeading != nil || entry.ratingScore > 0 || entry.hasPDF
    }

    private var ratingText: String {
        let s = entry.ratingScore
        return s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
    }
}
