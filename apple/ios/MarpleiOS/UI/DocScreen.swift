import SwiftUI
import MarpleKit

struct DocScreen: View {
    @Bindable var model: ReaderModel
    let entry: Entry
    @State private var rendered = NSAttributedString()
    @State private var stats: DocStats?
    @State private var outline: [OutlineItem] = []
    /// 本书 context (overview + chapters) when this doc is a book or chapter —
    /// same derivation the Mac inspector uses (QUA-202).
    @State private var book: BookContext?
    @State private var showInfo = false
    @State private var showOutline = false
    // Chapter navigation: the sheet records the tapped path, the push happens in
    // onDismiss so it doesn't race the sheet's dismissal animation.
    @State private var pendingPush: String?
    @State private var pushedPath: String?
    @State private var showFontControl = false
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
        MarkdownTextView(attributed: rendered, scrollTarget: scrollTarget, scrollNonce: scrollNonce)
            // No bar title — the document's own H1 is the title (Ulysses/Notes
            // style); the bar is just the system glass back circle + the ⋯ menu.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showFontControl = true } label: {
                            Label("字号", systemImage: "textformat.size")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) { floatingControls }
            .sheet(isPresented: $showOutline) {
                OutlineSheet(outline: outline) { item in
                    guard let r = item.characterRange else { return }
                    scrollTarget = r
                    scrollNonce += 1
                    showOutline = false
                }
                .presentationDetents([.fraction(0.5), .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showInfo, onDismiss: {
                if let p = pendingPush { pendingPush = nil; pushedPath = p }
            }) {
                InfoSheet(entry: entry, stats: stats, book: book) { target in
                    if target.path != entry.path { pendingPush = target.path }
                    showInfo = false
                }
                .presentationDetents([.fraction(0.5), .large])
                .presentationDragIndicator(.visible)
            }
            .navigationDestination(item: $pushedPath) { path in
                if let target = model.entries.first(where: { $0.path == path }) {
                    DocScreen(model: model, entry: target)
                }
            }
            .sheet(isPresented: $showFontControl) {
                FontControlSheet(size: $fontSize)
                    .presentationDetents([.height(160)])
                    .presentationDragIndicator(.visible)
            }
            .task(id: entry.id) { await load() }
            .onChange(of: fontSize) { _, _ in Task { await load() } }
    }

    /// Ulysses-style floating pill, bottom-right and thumb-reachable: outline +
    /// info. Typography moved to the ⋯ menu (low-frequency, Ulysses keeps it
    /// out of the reading surface too).
    private var floatingControls: some View {
        HStack(spacing: 2) {
            Button { showOutline = true } label: {
                Image(systemName: "list.bullet").frame(width: 44, height: 44)
            }
            .disabled(outline.isEmpty)
            Divider().frame(height: 22)
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").frame(width: 44, height: 44)
            }
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.trailing, 18)
        .padding(.bottom, 24)
    }

    private func load() async {
        let raw = await model.text(for: entry)
        let md = Wikilink.preprocessForRendering(raw)
        let doc = MarkdownRenderer.render(md, style: style)
        rendered = doc.attributedString
        outline = MarpleKit.outline(from: doc.headings)
        stats = computeDocStats(raw)
        book = bookContext(for: entry, in: model.entries)
    }
}

// MARK: - Outline sheet (its own half-height sheet, Ulysses-style)

private struct OutlineSheet: View {
    let outline: [OutlineItem]
    let onJump: (OutlineItem) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                sheetTitle("大纲")
                VStack(spacing: 0) {
                    ForEach(Array(outline.enumerated()), id: \.element.id) { idx, item in
                        Button { onJump(item) } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(item.level <= 1 ? Color.primary.opacity(0.5) : Color.secondary.opacity(0.35))
                                    .frame(width: item.level <= 1 ? 6 : 4, height: item.level <= 1 ? 6 : 4)
                                Text(item.text)
                                    .font(item.level <= 1 ? .callout.weight(.medium) : .callout)
                                    .foregroundStyle(item.level <= 1 ? .primary : .secondary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat((item.level - 1) * 16))
                            .padding(.vertical, 9).padding(.horizontal, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < outline.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .card()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Info sheet (Ulysses-style: stats + metadata cards + timestamp footnote)

private struct InfoSheet: View {
    let entry: Entry
    let stats: DocStats?
    let book: BookContext?
    let onOpen: (Entry) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let s = stats { statsCard(s) }
                if !bookRows.isEmpty { bookCard }
                infoCard
                timestamps
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Ulysses-style stats: left-aligned lines, number primary + unit secondary —
    /// not a three-column dashboard.
    private func statsCard(_ s: DocStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statLine("\(s.chars.formatted())", "字符")
            statLine("\(s.words.formatted())", "字")
            statLine("\(s.minutes)", "分钟 阅读时间")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14).padding(.horizontal, 14)
        .card()
    }

    private func statLine(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.callout).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// 本书 navigation rows (概述 + ordered chapters), mirroring the Mac
    /// inspector's BookNavGroup. Empty when there's nowhere else to go —
    /// a card listing only the page you're on would be noise.
    private var bookRows: [BookRow] {
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

    private var bookCard: some View {
        VStack(spacing: 0) {
            sectionHeader("本书")
            let rows = bookRows
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                let active = row.entry.path == entry.path
                Button { onOpen(row.entry) } label: {
                    HStack(spacing: 10) {
                        Text(row.label)
                            .font(active ? .callout.weight(.medium) : .callout)
                            .foregroundStyle(active ? Color.accentColor : Color.primary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if !active {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if idx < rows.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .card()
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            sectionHeader("信息")
            infoRow("类型", entry.type.label)
            if !entry.author.isEmpty { divider; infoRow("作者", entry.author.joined(separator: ", ")) }
            if let y = entry.year { divider; infoRow("年份", y) }
            if !entry.themes.isEmpty { divider; infoRow("主题", entry.themes.joined(separator: " · ")) }
        }
        .card()
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
            .padding(.horizontal, 4)
        }
    }

    private var divider: some View { Divider().padding(.leading, 14) }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).font(.callout).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 14)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
    }
}

/// One 本书 row resolved for display (Entry isn't Hashable, tuples aren't
/// Identifiable — this carries both the target and its display label).
private struct BookRow: Identifiable {
    let entry: Entry
    let label: String
    var id: String { entry.path }
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
                            .background(Color(.secondarySystemBackground),
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

/// Small secondary title above a sheet's first card (the "大纲" header in
/// Ulysses' outline sheet) — shared by both sheets.
private func sheetTitle(_ title: String) -> some View {
    HStack {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
    }
    .padding(.horizontal, 14).padding(.bottom, 8)
}

// MARK: - Card styling (rounded, hairline-bordered grouped card)

private extension View {
    func card() -> some View {
        self
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
