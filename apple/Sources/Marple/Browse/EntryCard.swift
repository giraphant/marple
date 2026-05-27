import SwiftUI
import AppKit
import MarpleKit

/// One masonry browse card. Text entries show metadata/prose; image entries show
/// the local original asset first, then the same object metadata.
struct EntryCard: View {
    let entry: Entry
    let imageOriginalURL: ((String) async -> URL?)?

    init(entry: Entry, imageOriginalURL: ((String) async -> URL?)? = nil) {
        self.entry = entry
        self.imageOriginalURL = imageOriginalURL
    }

    var body: some View {
        if entry.type == .image {
            ImageEntryCard(entry: entry, imageOriginalURL: imageOriginalURL)
        } else {
            TextEntryCard(entry: entry)
        }
    }
}

private struct TextEntryCard: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            MetaRow(entry: entry)

            Text(entry.title ?? fallbackTitle)
                .font(Typo.headline)
                .lineLimit(2)

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
    let imageOriginalURL: ((String) async -> URL?)?
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            imagePreview

            Text(entry.title ?? fallbackTitle)
                .font(Typo.headline)
                .lineLimit(2)

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
