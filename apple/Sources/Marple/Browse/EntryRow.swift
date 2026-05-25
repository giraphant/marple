import SwiftUI
import MarpleKit

/// List-row anatomy (spec §4): title + content preview + a calm meta line.
/// The preview's natural height variation is the "how much is here" signal —
/// replacing the old gold-star wall.
struct EntryRow: View {
    let entry: Entry

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
                    .lineLimit(3)
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
        }
        .padding(.vertical, Space.s5)
        .tag(entry.path)
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
