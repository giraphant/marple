import SwiftUI
import AppKit
import MarpleKit

// MARK: - WikiURL

enum WikiURL {
    static let scheme = "marple"
    static func make(_ target: String) -> URL? {
        let enc = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        return URL(string: "\(scheme)://wiki/\(enc)")
    }
    static func target(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let p = url.path
        return p.hasPrefix("/") ? String(p.dropFirst()) : p
    }
}

// MARK: - DocView

struct DocView: View {
    @Bindable var model: AppModel
    @Environment(\.readingFont) private var readingFont

    var body: some View {
        Group {
            if model.openPath == nil {
                ContentUnavailableView("选择一篇文档", systemImage: "doc.text")
            } else if model.openEntry?.type == .image {
                ImageObjectDetailView(model: model)
            } else {
                MarkdownTextView(
                    markdown: Wikilink.preprocessForRendering(model.openBody),
                    style: renderStyle,
                    scrollTarget: resolvedScrollTarget,
                    onLinkClick: { url in
                        if let target = WikiURL.target(from: url) {
                            Task { await model.follow(target) }
                            return true
                        }
                        return false
                    }
                )
            }
        }
    }

    private var renderStyle: RenderStyle {
        let design: MarkdownFontDesign
        switch readingFont.design {
        case .default:     design = .sans
        case .serif:       design = .serif
        case .monospaced:  design = .mono
        default:           design = .sans
        }
        return RenderStyle(size: readingFont.size, design: design, lineHeight: readingFont.lineHeight)
    }

    private var resolvedScrollTarget: NSRange? {
        guard let t = model.scrollTarget,
              let item = model.openOutline.first(where: { $0.blockIndex == t }),
              let range = item.characterRange else {
            return nil
        }
        return range
    }
}

private struct ImageObjectDetailView: View {
    @Bindable var model: AppModel
    @State private var image: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s6) {
                imageView

                if let entry = model.openEntry {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text(entry.title ?? fallbackTitle(for: entry))
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)

                        if let author = entry.author, !author.isEmpty {
                            Label(author, systemImage: "person")
                                .font(Typo.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let source = entry.source, !source.isEmpty {
                            Label(source, systemImage: "link")
                                .font(Typo.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !entry.themes.isEmpty {
                            Text(entry.themes.joined(separator: " · "))
                                .font(Typo.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                let notes = model.openBody.trimmingCharacters(in: .whitespacesAndNewlines)
                if !notes.isEmpty {
                    Divider()
                    Text(notes)
                        .font(Typo.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: Reading.measure, alignment: .leading)
            .padding(.horizontal, Space.s10)
            .padding(.vertical, Space.s9)
            .frame(maxWidth: .infinity)
        }
        .task(id: model.openPath) { await loadImage() }
    }

    @ViewBuilder private var imageView: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .aspectRatio(1.3, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func loadImage() async {
        guard let entry = model.openEntry,
              let url = try? await model.client.imageOriginalURL(forImageEntryPath: entry.path) else {
            image = nil
            return
        }
        let loaded = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
    }

    private func fallbackTitle(for entry: Entry) -> String {
        ImageAsset.slug(forImageEntryPath: entry.path)
            ?? (entry.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }
}
