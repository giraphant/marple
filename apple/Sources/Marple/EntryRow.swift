import SwiftUI
import MarpleKit

struct EntryRow: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title ?? "(untitled)").font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                if let a = entry.author, !a.isEmpty {
                    Text(a).lineLimit(1)
                }
                if let y = entry.year, !y.isEmpty {
                    Text(y)
                }
                if entry.ratingScore > 0 {
                    Text(String(repeating: "★", count: Int(entry.ratingScore.rounded())))
                        .foregroundStyle(.yellow)
                }
                if entry.hasPDF { Image(systemName: "doc.richtext").foregroundStyle(.secondary) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .tag(entry.path)
    }
}
