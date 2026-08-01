import SwiftUI
import MarpleKit

struct EntrySummaryRow: View {
    let entry: Entry
    var showsType = false

    private var title: String {
        entry.title ?? (entry.path as NSString).lastPathComponent
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if !entry.author.isEmpty { parts.append(ListFormatter.localizedString(byJoining: entry.author)) }
        if let year = entry.year, !year.isEmpty { parts.append(year) }
        return parts
    }

    private var preview: String {
        let trimmed = entry.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == title ? "" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if showsType || !metaParts.isEmpty {
                HStack(spacing: 6) {
                    if showsType {
                        Text(AppPresentation.entryTypeLabel(entry.type))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    if !metaParts.isEmpty {
                        Text(metaParts.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
