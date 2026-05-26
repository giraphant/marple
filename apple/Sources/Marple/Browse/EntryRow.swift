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
    /// When non-nil, the matched line whose `matchOrdinal` equals this value is
    /// the one currently anchored in the reader — render it with the dark-blue
    /// active cue per the Ulysses two-layer selection spec (QUA-95).
    var activeMatchOrdinal: Int? = nil
    var onToggleExpand: (() -> Void)? = nil
    var onMatchTap: ((BodyMatchLine) -> Void)? = nil

    private let matchCap = 3

    /// Title+preview area sized to ~4 lines of mixed type (headline 15pt + subheadline 13pt).
    /// `.layoutPriority(1)` on the title lets it claim its natural 1–2 lines first;
    /// the preview takes the remainder and naturally clamps to 3 lines (when title is 1)
    /// or 2 lines (when title is 2). Spec §4: "preview lineLimit 2–3" — i.e. title+preview
    /// always sums to 4 lines so cards stay equal-height regardless of title length.
    private static let titlePreviewBoxHeight: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(entry.title ?? "(untitled)")
                    .font(Typo.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                if !entry.preview.isEmpty {
                    Text(entry.preview)
                        .font(Typo.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(height: Self.titlePreviewBoxHeight, alignment: .topLeading)

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

    /// One step smaller than subheadline (13pt) — keeps matched-line text quieter
    /// than the preview without dropping all the way to caption (11pt).
    private static let matchedLineFont = Font.system(size: 12, weight: .regular)

    @ViewBuilder private var matchedLines: some View {
        if let matches, !matches.lines.isEmpty {
            let shown = expanded ? matches.lines : Array(matches.lines.prefix(matchCap))
            // VStack-spacing 0 + a tight 2pt vertical padding around each line means
            // total inter-line gap stays 4pt (down from 8pt) — the active accent
            // "pill" still has breathing room without looking airy.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { line in
                    let isActive = activeMatchOrdinal == line.matchOrdinal
                    Button { onMatchTap?(line) } label: {
                        Text(highlighted(line, active: isActive))
                            .font(Self.matchedLineFont)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.s2)
                            .padding(.vertical, Space.s1)
                            .background(
                                // Ulysses dark-blue active line: sits on top of
                                // the pale-blue row selection (from NSTableView
                                // sourceList style). Accent color so the cue
                                // follows the user's macOS accent.
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isActive ? Color.accentColor : Color.clear)
                            )
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
                            // Match the matched-line block's leading inset so the
                            // expand affordance left-aligns with the lines above.
                            .padding(.horizontal, Space.s2)
                            .padding(.vertical, Space.s1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, Space.s2)
        }
    }

    /// Build the matched-line text with the keyword spans tinted in the accent color.
    /// When `active` is true the line sits on a filled accent background, so the
    /// foreground flips to white and the in-text span highlight has to drop its
    /// own background (otherwise we'd get a double-tinted pill).
    private func highlighted(_ line: BodyMatchLine, active: Bool = false) -> AttributedString {
        var astr = AttributedString(line.excerpt)
        astr.foregroundColor = active ? Color.white : .secondary
        let excerpt = line.excerpt
        for span in line.spans {
            let nsr = NSRange(location: span.location, length: span.length)
            guard let r = Range(nsr, in: excerpt),
                  let lo = AttributedString.Index(r.lowerBound, within: astr),
                  let hi = AttributedString.Index(r.upperBound, within: astr) else { continue }
            if active {
                astr[lo..<hi].foregroundColor = Color.white
                astr[lo..<hi].font = Typo.subheadline.weight(.semibold)
            } else {
                astr[lo..<hi].backgroundColor = Color.accentColor.opacity(0.22)
                astr[lo..<hi].foregroundColor = Color.accentColor
            }
        }
        return astr
    }

    private var metaLeading: String? {
        var parts: [String] = []
        if let a = entry.author, !a.isEmpty { parts.append(a) }
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
