import SwiftUI
import AppKit
import MarpleKit

/// List-row anatomy (spec §4): title + content preview + a calm meta line.
/// The preview's natural height variation is the "how much is here" signal —
/// replacing the old gold-star wall.
struct EntryRow: View {
    let entry: Entry
    @Environment(\.ui) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            // Title (≤2 lines, ellipsis beyond) + preview fill one fixed 4-line
            // box: title 1 line → preview 3, title 2 lines → preview 2 (its 3rd
            // line is clipped at the box edge). The fixed height keeps every row
            // equal regardless of how much each has.
            VStack(alignment: .leading, spacing: ui.bodyLeading) {
                Text(entry.title ?? "(untitled)")
                    .font(ui.body.bold())
                    .foregroundStyle(.primary)
                    .lineSpacing(ui.bodyLeading)
                    .lineLimit(2)
                if !entry.preview.isEmpty {
                    Text(entry.preview)
                        .font(ui.body)
                        .foregroundStyle(.secondary)
                        .lineSpacing(ui.bodyLeading)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, minHeight: blockHeight, maxHeight: blockHeight,
                   alignment: .topLeading)
            .clipped()

            HStack(spacing: Space.s3) {
                // " " (not empty) so the line keeps its height even when an entry
                // has no author/year — every row reserves the same meta line.
                Text(metaLeading ?? " ").lineLimit(1)
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
            .font(ui.meta)
            .tracking(ui.metaTracking)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Space.s5)
        .tag(entry.path)
    }

    /// Height of a 4-line body block (4 lines + 3 inter-line gaps), used to pin
    /// every row to the same height. Derived from the body font's TextKit line
    /// height so it tracks the 界面字号 scale.
    private var blockHeight: CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: ui.bodySize))
        return 4 * lineHeight + 3 * ui.bodyLeading
    }

    /// The meta line's leading text, chosen by type so it isn't blank for kinds
    /// that lack author/year: authors show their themes, notes show a date.
    private var metaLeading: String? {
        switch entry.type {
        case .authorProfile:
            let themes = entry.themes.prefix(3).joined(separator: " · ")
            return themes.isEmpty ? nil : themes
        case .note:
            return noteDate
        case .topicSynthesis:
            return nil
        default:
            var parts: [String] = []
            if let a = entry.author, !a.isEmpty { parts.append(a) }
            if let y = entry.year, !y.isEmpty { parts.append(y) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// Absolute date (yyyy-MM-dd) from the git first-commit time, falling back to
    /// the file mtime. Both are epoch-ms; nil when neither is available.
    private var noteDate: String? {
        let added = entry.added ?? 0
        let ms = added > 0 ? added : (entry.mtime ?? 0)
        guard ms > 0 else { return nil }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var ratingText: String {
        let s = entry.ratingScore
        return s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
    }
}
