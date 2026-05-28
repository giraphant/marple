import SwiftUI
import AppKit
import MarpleKit

/// One masonry browse card. Text entries show metadata/prose; image entries show
/// the local original asset first, then the same object metadata.
struct EntryCard: View {
    let entry: Entry
    let imageOriginalURL: ((String) async -> URL?)?
    /// Vault-conformance flag (missing required frontmatter for this type). Defaults
    /// false so the card is identical when no schema snapshot exists.
    let nonConforming: Bool

    init(entry: Entry, nonConforming: Bool = false,
         imageOriginalURL: ((String) async -> URL?)? = nil) {
        self.entry = entry
        self.nonConforming = nonConforming
        self.imageOriginalURL = imageOriginalURL
    }

    var body: some View {
        if entry.type == .image {
            ImageEntryCard(entry: entry, nonConforming: nonConforming,
                           imageOriginalURL: imageOriginalURL)
        } else {
            TextEntryCard(entry: entry, nonConforming: nonConforming)
        }
    }
}

private struct TextEntryCard: View {
    let entry: Entry
    var nonConforming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            MetaRow(entry: entry)

            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text(entry.title ?? fallbackTitle)
                    .font(Typo.headline)
                    .lineLimit(2)
                if nonConforming { ConformanceDot() }
            }

            if !entry.preview.isEmpty {
                Text(entry.preview)
                    .font(Typo.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
            }

            ThemesLine(themes: entry.themes)
        }
        .padding(Space.s6)
        .cardChrome()
    }

    private var fallbackTitle: String {
        (entry.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }
}

private struct ImageEntryCard: View {
    let entry: Entry
    var nonConforming: Bool = false
    let imageOriginalURL: ((String) async -> URL?)?
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            imagePreview

            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text(entry.title ?? fallbackTitle)
                    .font(Typo.headline)
                    .lineLimit(2)
                if nonConforming { ConformanceDot() }
            }

            MetaRow(entry: entry)

            if let source = entry.source, !source.isEmpty {
                Text(source)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ThemesLine(themes: entry.themes)
        }
        .padding(Space.s4)
        .cardChrome()
        .task(id: entry.path) { await loadImage() }
    }

    @ViewBuilder private var imagePreview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(image.size.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(1.15, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func loadImage() async {
        guard let url = await imageOriginalURL?(entry.path) else {
            image = nil
            return
        }
        let loaded = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
    }

    private var fallbackTitle: String {
        ImageAsset.slug(forImageEntryPath: entry.path)
            ?? (entry.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }
}

private struct MetaRow: View {
    let entry: Entry

    var body: some View {
        if hasMeta {
            HStack(spacing: Space.s3) {
                if !entry.author.isEmpty { Text(entry.author.joined(separator: ", ")).lineLimit(1) }
                if let year = entry.year, !year.isEmpty { Text(year) }
                Spacer(minLength: 0)
                if entry.ratingScore > 0 {
                    HStack(spacing: Space.s1) {
                        Image(systemName: "star.fill")
                        Text(String(Int(entry.ratingScore.rounded()))).monospacedDigit()
                    }
                }
            }
            .font(Typo.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var hasMeta: Bool {
        !entry.author.isEmpty || (entry.year?.isEmpty == false) || entry.ratingScore > 0
    }
}

/// Subtle orange marker that a card's doc is missing required frontmatter for its
/// type, per `.quasi/schema.json`. See [[VaultConformance]].
private struct ConformanceDot: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(.orange)
            .help("缺少必填字段")
    }
}

private struct ThemesLine: View {
    let themes: [String]

    var body: some View {
        if !themes.isEmpty {
            Text(themes.prefix(4).joined(separator: " · "))
                .font(Typo.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

private extension View {
    func cardChrome() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

private extension NSSize {
    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return width / height
    }
}
