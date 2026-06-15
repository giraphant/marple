import SwiftUI
import MarpleKit

struct DocScreen: View {
    @Bindable var model: ReaderModel
    let entry: Entry
    @Environment(\.dismiss) private var dismiss
    @State private var rendered = NSAttributedString()
    @State private var stats: DocStats?
    @State private var outline: [OutlineItem] = []
    /// 本书 context (overview + chapters) when this doc is a book or chapter —
    /// same derivation the Mac inspector uses (QUA-202).
    @State private var book: BookContext?
    @State private var showInfo = false
    @State private var showOutline = false
    @State private var showOutlineAfterInfo = false
    // Chapter navigation: the sheet records the tapped path, the push happens in
    // onDismiss so it doesn't race the sheet's dismissal animation.
    @State private var pendingPush: String?
    @State private var pushedPath: String?
    @State private var showFontControl = false
    @State private var showBookContents = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var didOpenDemoOverlay = false
    #endif
    // Jump-to-section: bump the nonce on each outline tap so re-tapping the same
    // heading still scrolls (a plain NSRange wouldn't change value).
    @State private var scrollTarget: NSRange?
    @State private var scrollNonce = 0
    // Same option set as the Mac reader (ReadingDefaults.fontSizeOptions); 17 is a
    // comfortable phone default.
    @AppStorage("iosReadingFontSize") private var fontSize: Double = 17

    private var style: RenderStyle {
        RenderStyle(size: fontSize, fontFamily: nil, bodyWeight: .regular,
                    letterSpacing: 0, lineHeight: 1.6)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.systemBackground)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
            MarkdownTextView(attributed: rendered, scrollTarget: scrollTarget, scrollNonce: scrollNonce)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
            floatingControls
        }
            // No bar title — the document's own H1 is the title (Ulysses/Notes
            // style); the bar is just the system glass back circle + the ⋯ menu.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    readerToolbarMenu
                }
            }
            .sheet(isPresented: $showOutline) {
                OutlineSheet(outline: outline) { item in
                    guard let r = item.characterRange else { return }
                    scrollTarget = r
                    scrollNonce += 1
                    showOutline = false
                }
                .presentationDetents([.fraction(0.54), .large])
                .readerMaterialSheetChrome()
            }
            .sheet(isPresented: $showBookContents, onDismiss: {
                if let p = pendingPush { pendingPush = nil; pushedPath = p }
            }) {
                BookContentsSheet(entry: entry, book: book) { target in
                    if target.path != entry.path { pendingPush = target.path }
                    showBookContents = false
                }
                .presentationDetents([.fraction(0.54), .large])
                .readerMaterialSheetChrome()
            }
            .sheet(isPresented: $showInfo, onDismiss: {
                if showOutlineAfterInfo {
                    showOutlineAfterInfo = false
                    showOutline = true
                }
            }) {
                InfoSheet(entry: entry, stats: stats, canShowOutline: !outline.isEmpty) {
                    showOutlineAfterInfo = true
                    showInfo = false
                }
                    .presentationDetents([.large])
                    .readerMaterialSheetChrome()
            }
            .navigationDestination(item: $pushedPath) { path in
                if let target = model.entries.first(where: { $0.path == path }) {
                    DocScreen(model: model, entry: target)
                }
            }
            .sheet(isPresented: $showFontControl) {
                FontControlSheet(size: $fontSize)
                    .presentationDetents([.height(160)])
                    .readerSheetChrome()
            }
            .task(id: entry.id) {
                await load()
            }
            .onChange(of: fontSize) { _, _ in Task { await load() } }
    }

    /// Ulysses-style floating reading chrome: outline + statistics/details.
    /// Typography stays in the ⋯ menu, keeping this control focused on reading
    /// state rather than generic document commands.
    private var floatingControls: some View {
        ReaderFloatingControls(
            canShowOutline: !outline.isEmpty,
            canShowBookContents: !bookRows(for: book, current: entry).isEmpty,
            onOutline: {
                showOutline = true
            },
            onBookContents: {
                showBookContents = true
            },
            onInfo: {
                showInfo = true
            }
        )
        .padding(.trailing, 28)
        .padding(.bottom, 8)
        .offset(y: 16)
    }

    private var readerToolbarMenu: some View {
        Menu {
            Button {
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
            }
            Button {} label: {
                Label("前进", systemImage: "chevron.right")
            }
            .disabled(true)

            Divider()

            Button {
                showFontControl = true
            } label: {
                Label("字号", systemImage: "textformat.size")
            }
            Button {
                showOutline = true
            } label: {
                Label("大纲", systemImage: "list.bullet")
            }
            .disabled(outline.isEmpty)
            Button {
                showInfo = true
            } label: {
                Label("详情", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
        }
        .accessibilityLabel("更多")
    }

    private func load() async {
        let raw = await model.text(for: entry)
        // Strip YAML frontmatter before rendering/stats, same as the Mac reader
        // (metadata lives in the info sheet, not the reading surface).
        let body = Frontmatter.split(raw).body
        let md = Wikilink.preprocessForRendering(body)
        let doc = MarkdownRenderer.render(md, style: style)
        rendered = doc.attributedString
        outline = MarpleKit.outline(from: doc.headings)
        stats = computeDocStats(body)
        book = bookContext(for: entry, in: model.entries)
        #if DEBUG && targetEnvironment(simulator)
        openInitialDemoOverlayIfNeeded()
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    private func openInitialDemoOverlayIfNeeded() {
        guard !didOpenDemoOverlay,
              DemoVaultWorkspace.shouldOpenReader,
              let overlay = DemoVaultWorkspace.initialReaderOverlay else { return }
        didOpenDemoOverlay = true
        switch overlay {
        case .outline:
            showOutline = !outline.isEmpty
        case .contents:
            showBookContents = !bookRows(for: book, current: entry).isEmpty
        case .info:
            showInfo = true
        case .font:
            showFontControl = true
        }
    }
    #endif

}

private struct ReaderFloatingControls: View {
    let canShowOutline: Bool
    let canShowBookContents: Bool
    let onOutline: () -> Void
    let onBookContents: () -> Void
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ReaderFloatingControlIconButton(
                icon: "list.bullet",
                label: "大纲",
                isEnabled: canShowOutline,
                action: onOutline
            )

            if canShowBookContents {
                ReaderFloatingDivider()
                ReaderFloatingControlIconButton(
                    icon: "book.closed",
                    label: "目录",
                    action: onBookContents
                )
            }

            ReaderFloatingDivider()
            ReaderFloatingControlIconButton(
                icon: "speedometer",
                label: "详情",
                action: onInfo
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .foregroundStyle(.primary)
        .readerGlassCapsule()
        .accessibilityElement(children: .contain)
    }
}

private struct ReaderFloatingControlIconButton: View {
    let icon: String
    let label: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.55))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
        .accessibilityLabel(label)
    }
}

private struct ReaderFloatingDivider: View {
    var body: some View {
        Divider()
            .frame(height: 22)
    }
}

// MARK: - Outline sheet (its own half-height sheet, Ulysses-style)

private struct OutlineSheet: View {
    let outline: [OutlineItem]
    let onJump: (OutlineItem) -> Void

    // Ulysses geometry: hierarchy is expressed by indentation only; every level
    // gets the same primary text and dot.
    private func indent(_ item: OutlineItem) -> CGFloat { CGFloat(max(item.level - 1, 0)) * 20 }

    var body: some View {
        List {
            Section {
                ForEach(outline, id: \.id) { item in
                    Button { onJump(item) } label: {
                        // Top-aligned so the dot anchors to the first line of a
                        // wrapped heading, not the center of the whole block.
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(Color.secondary.opacity(0.36))
                                .frame(width: 6, height: 6)
                                .padding(.top, 7)
                            Text(item.text)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, indent(item))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
                }
            } header: {
                Text("大纲")
                    .font(.system(size: 15))
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 27, for: .scrollContent)
        .background(Color.clear)
    }
}

// MARK: - Info sheet (Ulysses-style: stats + metadata cards + timestamp footnote)

private struct InfoSheet: View {
    let entry: Entry
    let stats: DocStats?
    let canShowOutline: Bool
    let onOutline: () -> Void

    var body: some View {
        List {
            if let s = stats {
                Section {
                    statsRows(s)
                        .listRowInsets(EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20))
                }
            }

            if canShowOutline {
                Section {
                    outlineAction
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }

            Section {
                infoRow("类型", entry.type.label)
                if !entry.author.isEmpty { infoRow("作者", entry.author.joined(separator: ", ")) }
                if let y = entry.year { infoRow("年份", y) }
                if !entry.themes.isEmpty { infoRow("主题", entry.themes.joined(separator: " · ")) }
            }

            if hasTimestamps {
                Section {
                    timestamps
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 65, for: .scrollContent)
        .background(Color.clear)
    }

    /// Ulysses-style stats: left-aligned lines, number primary + unit secondary —
    /// not a three-column dashboard.
    private func statsRows(_ s: DocStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            statLine("\(s.chars.formatted())", "字符")
            statLine("\(s.words.formatted())", "字")
            statLine("\(s.minutes)", "分钟 阅读时间")
        }
        .padding(.top, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statLine(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.system(size: 18))
    }

    private var outlineAction: some View {
        Button(action: onOutline) {
            HStack(spacing: 15) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 24)
                Text("大纲")
                    .font(.system(size: 18))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Ulysses-style trailing footnote: plain secondary text below the cards,
    /// no card chrome. Absolute dates — this is a knowledge base, not a feed.
    @ViewBuilder
    private var timestamps: some View {
        let modified = entry.mtime.map { Date(timeIntervalSince1970: $0 / 1000) }
        if entry.created != nil || modified != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let c = entry.created, !c.isEmpty {
                    Text("创建于:\(c)")
                }
                if let m = modified {
                    Text("修改于:\(m, format: .dateTime.year().month().day().hour().minute())")
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hasTimestamps: Bool {
        entry.created != nil || entry.mtime != nil
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).font(.subheadline).multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
    }

}

// MARK: - Book contents sheet

private struct BookContentsSheet: View {
    let entry: Entry
    let book: BookContext?
    let onOpen: (Entry) -> Void

    private var rows: [BookRow] {
        bookRows(for: book, current: entry)
    }

    var body: some View {
        List {
            Section {
                ForEach(rows, id: \.id) { row in
                    let active = row.entry.path == entry.path
                    Button { onOpen(row.entry) } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(active ? Color.accentColor : Color.secondary.opacity(0.44))
                                .frame(width: 6, height: 6)
                            Text(row.label)
                                .font(.system(size: 17, weight: active ? .medium : .regular))
                                .foregroundStyle(active ? Color.accentColor : Color.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if !active {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
                }
            } header: {
                Text("目录")
                    .font(.system(size: 15))
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 27, for: .scrollContent)
        .background(Color.clear)
    }
}

/// One 本书 row resolved for display (Entry isn't Hashable, tuples aren't
/// Identifiable — this carries both the target and its display label).
private struct BookRow: Identifiable {
    let entry: Entry
    let label: String
    var id: String { entry.path }
}

private func bookRows(for book: BookContext?, current entry: Entry) -> [BookRow] {
    guard let b = book else { return [] }
    var rows: [BookRow] = []
    if let ov = b.overview { rows.append(BookRow(entry: ov, label: "概述")) }
    rows += b.chapters.map { BookRow(entry: $0, label: chapterLabel($0)) }
    guard rows.contains(where: { $0.entry.path != entry.path }) else { return [] }
    return rows
}

private func chapterLabel(_ e: Entry) -> String {
    if let t = e.title, !t.isEmpty { return t }
    return (e.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
}

// MARK: - Font size control

private struct FontControlSheet: View {
    @Binding var size: Double
    private let options: [Double] = [15, 16, 17, 18, 19]

    var body: some View {
        VStack(spacing: 16) {
            Text("字号").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { opt in
                    Button { size = opt } label: {
                        Text("\(Int(opt))")
                            .font(.system(size: 17, weight: size == opt ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color(.secondarySystemBackground).opacity(0.82),
                                        in: RoundedRectangle(cornerRadius: 10))
                            // Selected = accent stroke, not a filled block — quieter.
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(size == opt ? Color.accentColor : .clear, lineWidth: 1.5))
                            .foregroundStyle(size == opt ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private extension View {
    func readerSheetChrome() -> some View {
        self
            .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    func readerMaterialSheetChrome() -> some View {
        if #available(iOS 26.0, *) {
            self.presentationDragIndicator(.visible)
        } else {
            self.presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    func readerGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }

}
