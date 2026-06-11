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

// MARK: - SeekURL

/// `marple://seek/<seconds>` — emitted by `TalkTimeline` for a talk/transcript
/// timestamp; intercepted to seek the media player.
enum SeekURL {
    static func seconds(from url: URL) -> Double? {
        guard url.scheme == TalkTimeline.scheme, url.host == TalkTimeline.host else { return nil }
        let raw = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        return Double(raw)
    }
}

// MARK: - DocView

struct DocView: View {
    @Bindable var model: AppModel
    @Environment(\.readingFont) private var readingFont
    @State private var playerEnlarged = false

    var body: some View {
        Group {
            if model.openPath == nil {
                ContentUnavailableView("选择一篇文档", systemImage: "doc.text")
            } else if model.openEntry?.type == .image {
                ImageObjectDetailView(model: model)
            } else {
                MarkdownTextView(
                    markdown: renderedMarkdown,
                    style: renderStyle,
                    documentID: model.openPath ?? "",
                    scrollTargetOrdinal: resolvedScrollOrdinal,
                    highlightQuery: model.openSearchQuery,
                    jump: model.matchJump,
                    onLinkClick: { url in
                        if let seconds = SeekURL.seconds(from: url) {
                            model.playTalk(seconds: seconds)
                            return true
                        }
                        if let target = WikiURL.target(from: url) {
                            Task { await model.follow(target) }
                            return true
                        }
                        return false
                    }
                )
            }
        }
        // Non-modal floating player: a `.sheet` would disable the reader and make
        // timestamp-to-timestamp re-seeking impossible. A bottom-trailing overlay
        // keeps the body clickable so each `[mm:ss]` drives the player. The
        // GeometryReader hands the player the reader size so "放大" can fit 16:9.
        .overlay(alignment: .bottomTrailing) {
            if model.talkPlayback != nil {
                GeometryReader { geo in
                    TalkPlayerView(model: model, availableSize: geo.size, enlarged: $playerEnlarged)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(Space.s6)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.talkPlayback != nil)
        .overlay(alignment: .top) { toastOverlay }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.toast)
        // QUA-105: same bootstrap fade-in as BrowseColumn. Doc area starts
        // invisible (matching the empty `openBody` during bootstrap) and
        // eases in once the first loadIndex has published.
        .opacity(model.isBootstrapping ? 0.0 : 1.0)
        .animation(.easeOut(duration: 0.22), value: model.isBootstrapping)
    }

    @ViewBuilder private var toastOverlay: some View {
        if let toast = model.toast {
            ToastBanner(text: toast.text, symbol: toast.symbol)
                .id(toast.id)
                .padding(.top, Space.s7)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(1.6))
                    if model.toast?.id == toast.id { model.toast = nil }
                }
        }
    }

    /// Wikilink-preprocessed body, additionally linkifying `[mm:ss]` timestamps
    /// for talk/transcript documents — but only when the recording exists on this
    /// machine, so media-less clones keep plain (non-dead) timestamps.
    private var renderedMarkdown: String {
        let wikis = Wikilink.preprocessForRendering(model.openBody)
        guard let entry = model.openEntry,
              entry.type == .talk || entry.type == .transcript,
              model.client.talkMediaURL(forEntryPath: entry.path) != nil else { return wikis }
        return TalkTimeline.linkifyTimestamps(wikis)
    }

    private var renderStyle: RenderStyle {
        RenderStyle(size: readingFont.size,
                    fontFamily: readingFont.fontFamily,
                    bodyWeight: readingFont.bodyWeight,
                    letterSpacing: readingFont.letterSpacing,
                    lineHeight: readingFont.lineHeight)
    }

    /// The clicked outline item's position in the outline. The Inspector stores its
    /// `blockIndex` (a font-free RenderBlock index) in `scrollTarget`; the live text
    /// view turns this ordinal back into a character range (QUA-227).
    private var resolvedScrollOrdinal: Int? {
        guard let t = model.scrollTarget else { return nil }
        return model.openOutline.firstIndex(where: { $0.blockIndex == t })
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

                        if !entry.author.isEmpty {
                            Label(entry.author.joined(separator: ", "), systemImage: "person")
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

/// Transient confirmation banner (e.g. 已复制引用), floated near the reader's top.
private struct ToastBanner: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: symbol).foregroundStyle(.green)
            Text(text).font(Typo.body)
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }
}
