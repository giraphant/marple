import SwiftUI
import MarpleKit

/// List-row anatomy (spec §4): title + content preview + a calm meta line.
/// The preview's natural height variation is the "how much is here" signal —
/// replacing the old gold-star wall.
///
/// In search mode, the matched lines and the "再显示 N 个" toggle are their
/// OWN rows in the table now (flat-row architecture per Ulysses' keyboard-nav
/// behavior — each match line is an independent ↑↓ stop, not a subview of the
/// entry row). See `EntryListTable.RowItem`.
struct EntryRow: View {
    let entry: Entry

    /// Vault-conformance flag: true when this doc is missing required frontmatter
    /// for its type, per `.quasi/schema.json`. Defaults false so the row is
    /// identical when no schema snapshot exists. See [[VaultConformance]].
    var nonConforming: Bool = false

    /// Title+preview area sized to ~4 lines of mixed type (headline 15pt + subheadline 13pt).
    /// `.layoutPriority(1)` on the title lets it claim its natural 1–2 lines first;
    /// the preview takes the remainder and naturally clamps to 3 lines (when title is 1)
    /// or 2 lines (when title is 2). Spec §4: "preview lineLimit 2–3" — i.e. title+preview
    /// always sums to 4 lines so cards stay equal-height regardless of title length.
    private static let titlePreviewBoxHeight: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text(entry.title ?? "(untitled)")
                        .font(Typo.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    if nonConforming {
                        Spacer(minLength: Space.s2)
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.orange)
                            .help("缺少必填字段")
                    }
                }

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
        }
        .padding(.vertical, Space.s5)
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
