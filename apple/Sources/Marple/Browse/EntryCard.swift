import SwiftUI
import MarpleKit

/// One masonry browse card: meta · title · preview · themes. Uses the layout
/// tokens (Space) + the scaled UI type scale (\.ui); colors ride system semantic
/// colors (spec §1.3).
struct EntryCard: View {
    let entry: Entry
    @Environment(\.ui) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if hasMeta {
                HStack(spacing: Space.s3) {
                    if let a = entry.author, !a.isEmpty { Text(a).lineLimit(1) }
                    if let y = entry.year, !y.isEmpty { Text(y) }
                    Spacer(minLength: 0)
                    if entry.ratingScore > 0 {
                        HStack(spacing: Space.s1) {
                            Image(systemName: "star.fill")
                            Text(String(Int(entry.ratingScore.rounded()))).monospacedDigit()
                        }
                    }
                }
                .font(ui.meta)
                .tracking(ui.metaTracking)
                .foregroundStyle(.secondary)
            }

            Text(entry.title ?? fallbackTitle)
                .font(ui.headline)
                .lineLimit(2)

            if !entry.preview.isEmpty {
                Text(entry.preview)
                    .font(ui.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
            }

            if !entry.themes.isEmpty {
                Text(entry.themes.prefix(4).joined(separator: " · "))
                    .font(ui.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var hasMeta: Bool {
        (entry.author?.isEmpty == false) || (entry.year?.isEmpty == false) || entry.ratingScore > 0
    }
    private var fallbackTitle: String {
        (entry.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }
}
