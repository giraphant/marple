import SwiftUI
import AppKit
import MarpleKit

/// Ulysses-style right inspector: a tabbed panel with three independent sections
/// — 信息 / 目录 / 统计 — picked via a top icon strip. Only the active section
/// renders, instead of stacking all three in one scroll.
struct InspectorView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .info

    private enum Tab: Hashable { case info, outline, stats }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .info:    InfoSection(model: model)
                    case .outline: OutlineSection(model: model)
                    case .stats:   StatsSection(stats: model.openStats)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: Space.s4) {
            tabButton(.info, "list.bullet.rectangle", "信息")
            tabButton(.outline, "list.number", "目录")
            tabButton(.stats, "chart.bar", "统计")
        }
        .padding(.vertical, Space.s4)
    }

    private func tabButton(_ t: Tab, _ symbol: String, _ label: String) -> some View {
        Button { tab = t } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 22)
                .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.15))
                        .opacity(tab == t ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Shared bits

private struct SectionHeader: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        // No .uppercase: it does nothing for Chinese and only harms Latin labels (spec §6).
        Text(title).font(Typo.caption).fontWeight(.semibold)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - 统计

private struct StatsSection: View {
    let stats: DocStats?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("统计")
            if let s = stats {
                StatRow("字符", "\(s.chars)")
                StatRow("字", "\(s.words)")
                StatRow("段落", "\(s.paragraphs)")
                StatRow("阅读时间", s.minutes > 0 ? "\(s.minutes) 分钟" : "—")
            } else {
                Text("—").foregroundStyle(.secondary).font(.callout)
            }
        }
    }
}

private struct StatRow: View {
    let label: String, value: String
    init(_ l: String, _ v: String) { label = l; value = v }
    var body: some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
            .font(.callout)
    }
}

// MARK: - 目录

private struct OutlineSection: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let book = model.openBook {
                BookNavGroup(model: model, book: book)
            }
            PageOutlineGroup(model: model, labeled: model.openBook != nil)
        }
    }
}

/// EPUB-style "本书" navigation: the book's overview + its chapters, with the
/// currently-open doc highlighted. Tapping a row navigates the active tab in
/// place (pushes history, so ◀ returns), matching chapter-to-chapter reading.
private struct BookNavGroup: View {
    @Bindable var model: AppModel
    let book: BookContext
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            SectionHeader("本书")
            if let ov = book.overview {
                BookNavRow(label: "概述",
                           active: model.openPath == ov.path) { navigate(to: ov.path) }
            }
            ForEach(book.chapters) { ch in
                BookNavRow(label: chapterLabel(ch),
                           active: model.openPath == ch.path) { navigate(to: ch.path) }
            }
        }
    }

    private func navigate(to path: String) {
        guard path != model.openPath else { return }
        Task { await model.open(path) }
    }

    private func chapterLabel(_ e: Entry) -> String {
        if let t = e.title, !t.isEmpty { return t }
        return (e.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }
}

/// One book-navigation row: accent fill when it's the open doc, a quaternary
/// hover fill otherwise — same affordance as RelationRow (spec §6).
private struct BookNavRow: View {
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label).font(Typo.callout).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Space.s1).padding(.horizontal, Space.s2)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
                .opacity(active ? 1 : 0)
        }
        .background {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                .opacity(!active && hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

/// The open document's own heading outline. Labelled "本页" when a book is in
/// context (to pair with "本书"), else "目录" — the standalone case.
private struct PageOutlineGroup: View {
    @Bindable var model: AppModel
    let labeled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(labeled ? "本页" : "目录")
            if model.openOutline.isEmpty {
                Text("无标题").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(model.openOutline) { item in
                    Button { model.scrollTarget = item.blockIndex } label: {
                        Text(item.text)
                            .font(.callout).lineLimit(1)
                            .padding(.leading, CGFloat((item.level - 1) * 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 信息

// Mirror FIELDS_BY_TYPE (PropertyPanel.tsx); themes handled separately.
private func editableFields(for type: EntryType) -> Set<String> {
    switch type {
    case .paperAnalysis:  return ["rating", "year", "source", "doi", "topic"]
    case .bookOverview:   return ["rating", "year", "source", "topic"]
    case .chapterSummary: return ["rating", "year", "source", "topic"]
    case .authorProfile:  return ["rating"]
    case .topicSynthesis: return ["rating", "topic"]
    case .note:           return []
    case .other:          return []
    }
}

private struct InfoSection: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("信息")
            if let err = model.writeError {
                Text("保存失败：\(err)").font(.caption).foregroundStyle(.red)
            }
            if let e = model.openEntry {
                let fields = editableFields(for: e.type)
                VStack(alignment: .leading, spacing: 8) {
                    if fields.contains("rating") { RatingRow(model: model, score: Int(e.ratingScore)) }
                    if fields.contains("year") {
                        ScalarRow(model: model, label: "年份", value: e.year) { await model.setYear($0) }
                    }
                    if e.author?.isEmpty == false { AuthorRow(model: model, entry: e) }
                    if fields.contains("source") {
                        ScalarRow(model: model, label: "来源", value: e.source) { await model.setSource($0) }
                    }
                    if fields.contains("doi") {
                        ScalarRow(model: model, label: "DOI", value: e.doi) { await model.setDoi($0) }
                    }
                    if fields.contains("topic") {
                        ScalarRow(model: model, label: "专题", value: e.topic) { await model.setTopic($0) }
                    }
                }
                .disabled(model.savingField != nil)
                ThemesEditor(model: model, themes: e.themes)
                RelationsView(model: model)
                CitationControl(entry: e).id(e.path)
            } else {
                Text("—").foregroundStyle(.secondary).font(.callout)
            }
        }
    }
}

private struct RatingRow: View {
    @Bindable var model: AppModel
    let score: Int
    var body: some View {
        HStack {
            Text("评分").foregroundStyle(.secondary)
            Spacer()
            ForEach(1...5, id: \.self) { n in
                Button { Task { await model.setRating(n == score ? nil : n) } } label: {
                    Image(systemName: n <= score ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.yellow)
            }
        }
        .font(.callout)
    }
}

private struct ScalarRow: View {
    @Bindable var model: AppModel
    let label: String
    let value: String?
    let commit: (String?) async -> Void
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if editing {
                TextField(label, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 170)
                    .onSubmit { Task { await commit(draft); editing = false } }
            } else {
                Button {
                    draft = value ?? ""
                    editing = true
                } label: {
                    Text(value?.isEmpty == false ? value! : "—")
                        .foregroundStyle(value?.isEmpty == false ? .primary : .secondary)
                        .multilineTextAlignment(.trailing)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
    }
}

private struct AuthorRow: View {
    @Bindable var model: AppModel
    let entry: Entry
    var body: some View {
        HStack {
            Text("作者").foregroundStyle(.secondary)
            Spacer()
            if let prof = model.openRelations?.authorProfile {
                Button { Task { await model.open(prof.path) } } label: {
                    Text(entry.author ?? "").lineLimit(1)
                }
                .buttonStyle(.link)
            } else {
                Text(entry.author ?? "").lineLimit(1)
            }
        }
        .font(.callout)
    }
}

private struct ThemesEditor: View {
    @Bindable var model: AppModel
    let themes: [String]
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader("主题")
                Spacer()
                Button(adding ? "取消" : "+ 添加") { adding.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            if themes.isEmpty {
                Text("—").foregroundStyle(.secondary).font(.callout)
            } else {
                FlowLayout(spacing: Space.s2, lineSpacing: Space.s2) {
                    ForEach(themes, id: \.self) { t in
                        ThemeChip(
                            theme: t,
                            onTap: { model.select(pane: .theme(t)) },
                            onRemove: { Task { await model.removeTheme(t) } }
                        )
                    }
                }
            }
            if adding {
                TextField("新主题（逗号分隔可多个）", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.addThemes(draft); draft = ""; adding = false } }
            }
        }
        .disabled(model.savingField != nil)
    }
}

private struct ThemeChip: View {
    let theme: String
    let onTap: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.s1) {
            Button(theme) { onTap() }.buttonStyle(.plain)
            if hovering {
                Button { onRemove() } label: {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .font(Typo.caption2)
        .padding(.horizontal, Space.s3).padding(.vertical, Space.s1)
        .background(.quaternary, in: Capsule())
        .onHover { hovering = $0 }
    }
}

private struct RelationsView: View {
    @Bindable var model: AppModel
    var body: some View {
        if let r = model.openRelations {
            VStack(alignment: .leading, spacing: 14) {
                relGroup("作者作品", r.works)
                relGroup("同作者", r.siblings)
                relGroup("同主题相似", r.similar)
                relGroup("我的批注", r.annotations)
            }
        }
    }

    @ViewBuilder private func relGroup(_ title: String, _ list: [Entry]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: Space.s1) {
                SectionHeader("\(title) (\(list.count))")
                ForEach(list.prefix(30)) { e in
                    RelationRow(title: e.title ?? e.path) { Task { await model.open(e.path) } }
                }
            }
        }
    }
}

/// A relation link that shows a hover background so it reads as clickable (spec §6).
private struct RelationRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.callout).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Space.s1).padding(.horizontal, Space.s2)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary).opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - 引用

/// One-tap citation copy mirroring the web ActionsRow: a format menu (seeded from
/// the default in Settings, overridable per use), a live preview, and a copy
/// button. Reset per document via `.id(entry.path)` at the call site.
private struct CitationControl: View {
    let entry: Entry
    @AppStorage(SettingsKeys.citationFormat) private var defaultFormat = CitationFormat.inlineEN
    @State private var override: CitationFormat?
    @State private var copied = false

    private var format: CitationFormat { override ?? defaultFormat }

    var body: some View {
        let preview = buildCitation(entry, format: format)
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                SectionHeader("引用")
                Spacer()
                Menu {
                    ForEach(CitationFormat.allCases, id: \.self) { f in
                        Button {
                            override = f; copied = false
                        } label: {
                            if f == format { Label(f.label, systemImage: "checkmark") }
                            else { Text(f.label) }
                        }
                    }
                } label: {
                    Text(format.label)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
            }

            if preview.isEmpty {
                Text("缺少作者 / 年份等信息").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(preview)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(preview, forType: .string)
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            } label: {
                Label(copied ? "✓ 已复制" : "复制引用",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .disabled(preview.isEmpty)
        }
    }
}
