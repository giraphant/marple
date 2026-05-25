import SwiftUI
import AppKit
import MarpleKit

/// Ulysses-style right inspector: a tabbed panel with independent sections picked
/// via a top icon strip. Only the active section renders.
struct InspectorView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .info

    private enum Tab: Hashable { case info, outline, stats, notes }

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
                    case .notes:   NotesSection(model: model)
                    }
                }
                .padding(InspectorStyle.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            tabButton(.info, "doc.text", "信息")
            tabButton(.outline, "list.bullet.indent", "目录")
            tabButton(.stats, "chart.bar", "统计")
            tabButton(.notes, "text.bubble", "笔记")
        }
        .padding(.vertical, 6)
    }

    private func tabButton(_ t: Tab, _ symbol: String, _ label: String) -> some View {
        let active = tab == t
        return Button { tab = t } label: {
            Image(systemName: symbol)
                .symbolVariant(active ? .fill : .none)
                .font(.system(size: 13).weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 38, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Shared bits

private enum InspectorStyle {
    static let contentInset: CGFloat = 18
    static let sectionSpacing: CGFloat = 22
    static let headerSpacing: CGFloat = 10
    static let fieldLabelWidth: CGFloat = 62
    static let rowHeight: CGFloat = 26
    static let rowCorner: CGFloat = 7

    static let sectionTitle = Font.system(size: 11.5, weight: .bold)
    static let sectionTitleColor = Color(nsColor: .tertiaryLabelColor)
    static let rowLabelColor = Color(nsColor: .labelColor).opacity(0.82)
}

private struct SectionHeader: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        Text(title)
            .font(InspectorStyle.sectionTitle)
            .foregroundStyle(InspectorStyle.sectionTitleColor)
    }
}

private struct FieldRow<Value: View>: View {
    let label: String
    let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.s5) {
            Text(label)
                .font(Typo.callout)
                .fontWeight(.medium)
                .foregroundStyle(InspectorStyle.rowLabelColor)
                .frame(width: InspectorStyle.fieldLabelWidth, alignment: .leading)
            Spacer(minLength: 0)
            value
        }
        .frame(minHeight: InspectorStyle.rowHeight)
    }
}

// MARK: - 统计

private struct StatsSection: View {
    let stats: DocStats?
    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
            SectionHeader("统计")
            if let s = stats {
                VStack(alignment: .leading, spacing: 0) {
                    StatRow("字符", "\(s.chars)")
                    StatRow("字", "\(s.words)")
                    StatRow("段落", "\(s.paragraphs)")
                    StatRow("阅读时间", s.minutes > 0 ? "\(s.minutes) 分钟" : "—")
                }
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
        FieldRow(label) {
            Text(value)
                .font(Typo.callout)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

// MARK: - 目录

private struct OutlineSection: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.sectionSpacing) {
            if let book = model.openBook {
                BookNavGroup(model: model, book: book)
            }
            PageOutlineGroup(model: model)
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
        VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
            SectionHeader("本书")
            VStack(alignment: .leading, spacing: 0) {
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
            Text(label)
                .font(Typo.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4)
                .frame(minHeight: InspectorStyle.rowHeight)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: InspectorStyle.rowCorner)
                .fill(Color.accentColor.opacity(0.12))
                .opacity(active ? 1 : 0)
        }
        .background {
            RoundedRectangle(cornerRadius: InspectorStyle.rowCorner)
                .fill(.quaternary)
                .opacity(!active && hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

private struct PageOutlineGroup: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
            SectionHeader("页面目录")
            if model.openOutline.isEmpty {
                Text("无标题").foregroundStyle(.secondary).font(.callout)
            } else {
                let baseLevel = model.openOutline.map(\.level).min() ?? 1
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.openOutline) { item in
                        PageOutlineRow(item: item, baseLevel: baseLevel) { model.scrollTarget = item.blockIndex }
                    }
                }
            }
        }
    }
}

private struct PageOutlineRow: View {
    let item: OutlineItem
    let baseLevel: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                Circle()
                    .stroke(Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5)
                    .frame(width: 9, height: 9)
                Text(item.text)
                    .font(Typo.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(max(item.level - baseLevel, 0) * 14))
            .padding(.horizontal, Space.s4)
            .frame(minHeight: InspectorStyle.rowHeight)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: InspectorStyle.rowCorner)
                .fill(.quaternary)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
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
    case .image:          return ["title", "author", "source", "topic"]
    case .other:          return []
    }
}

private struct InfoSection: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.sectionSpacing) {
            if let e = model.openEntry {
                let fields = editableFields(for: e.type)
                VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
                    SectionHeader("信息")
                    if let err = model.writeError {
                        Text("保存失败：\(err)").font(.caption).foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        if fields.contains("rating") { RatingRow(model: model, score: Int(e.ratingScore)) }
                        if fields.contains("title") {
                            ScalarRow(model: model, label: "名称", value: e.title) { await model.setTitle($0) }
                        }
                        if fields.contains("year") {
                            ScalarRow(model: model, label: "年份", value: e.year) { await model.setYear($0) }
                        }
                        if fields.contains("author") {
                            ScalarRow(model: model, label: "作者", value: e.author) { await model.setAuthor($0) }
                        } else if e.author?.isEmpty == false {
                            AuthorRow(model: model, entry: e)
                        }
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
                }
                ThemesEditor(model: model, themes: e.themes)
                RelationsView(model: model)
            } else {
                VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
                    SectionHeader("信息")
                    Text("—").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
    }
}

private struct RatingRow: View {
    @Bindable var model: AppModel
    let score: Int
    @State private var hovering: Int?

    var body: some View {
        FieldRow("评分") {
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { n in
                    Button { Task { await model.setRating(n == score ? nil : n) } } label: {
                        Image(systemName: n <= score ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .regular))
                            .frame(width: 22, height: 22)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.quaternary)
                                    .opacity(hovering == n ? 1 : 0)
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.yellow)
                    .onHover { hovering = $0 ? n : nil }
                }
            }
        }
    }
}

private struct ScalarRow: View {
    @Bindable var model: AppModel
    let label: String
    let value: String?
    let commit: (String?) async -> Void
    @State private var draft = ""
    @State private var editing = false
    @State private var hovering = false

    var body: some View {
        FieldRow(label) {
            if editing {
                TextField(label, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 170, alignment: .trailing)
                    .onSubmit { Task { await commit(draft); editing = false } }
            } else {
                Button {
                    draft = value ?? ""
                    editing = true
                } label: {
                    Text(value?.isEmpty == false ? value! : "—")
                        .font(Typo.callout)
                        .foregroundStyle(value?.isEmpty == false ? .primary : .secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, Space.s3)
                        .padding(.vertical, Space.s1)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                                .opacity(hovering ? 1 : 0)
                        }
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            }
        }
    }
}

private struct AuthorRow: View {
    @Bindable var model: AppModel
    let entry: Entry
    var body: some View {
        FieldRow("作者") {
            if let prof = model.openRelations?.authorProfile {
                Button { Task { await model.open(prof.path) } } label: {
                    Text(entry.author ?? "").lineLimit(1)
                }
                .buttonStyle(.link)
            } else {
                Text(entry.author ?? "")
                    .font(Typo.callout)
                    .lineLimit(1)
            }
        }
    }
}

private struct ThemesEditor: View {
    @Bindable var model: AppModel
    let themes: [String]
    @State private var adding = false
    @State private var draft = ""
    @State private var hoveringAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
            HStack {
                SectionHeader("主题")
                Spacer()
                Button { adding.toggle() } label: {
                    Image(systemName: adding ? "xmark" : "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background {
                            Circle().fill(.quaternary).opacity(hoveringAdd ? 1 : 0)
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(adding ? "取消" : "添加主题")
                .onHover { hoveringAdd = $0 }
            }
            if themes.isEmpty {
                Button { adding = true } label: {
                    Text("添加主题")
                        .font(Typo.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                FlowLayout(spacing: Space.s3, lineSpacing: Space.s3) {
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
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .onHover { hovering = $0 }
    }
}

private struct NotesSection: View {
    @Bindable var model: AppModel
    private var notes: [Entry] { model.openRelations?.annotations ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
            SectionHeader(notes.isEmpty ? "笔记" : "笔记 (\(notes.count))")
            if notes.isEmpty {
                Text("暂无关联笔记").foregroundStyle(.secondary).font(Typo.callout)
            } else {
                VStack(alignment: .leading, spacing: Space.s1) {
                    ForEach(notes) { note in
                        NoteRow(entry: note) { Task { await model.open(note.path) } }
                    }
                }
            }
            Button { Task { await model.newAnnotationForOpenDoc() } } label: {
                Text("添加...")
                    .font(Typo.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.s2)
            }
            .buttonStyle(.plain)
            .disabled(model.openEntry == nil)
        }
    }
}

private struct NoteRow: View {
    let entry: Entry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title ?? fallbackTitle)
                    .font(Typo.callout)
                    .lineLimit(1)
                Text(entry.preview.isEmpty ? entry.path : entry.preview)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Space.s2)
            .padding(.horizontal, Space.s2)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary).opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }

    private var fallbackTitle: String {
        (entry.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }
}

private struct RelationsView: View {
    @Bindable var model: AppModel
    var body: some View {
        if let r = model.openRelations {
            VStack(alignment: .leading, spacing: InspectorStyle.sectionSpacing) {
                if !r.works.isEmpty {
                    let books = r.works.filter { $0.type == .bookOverview }
                    let papers = r.works.filter { $0.type == .paperAnalysis }
                    relGroup("图书", books)
                    relGroup("论文", papers)
                }
                relGroup("同作者", r.siblings)
                relGroup("同主题相似", r.similar)
            }
        }
    }

    @ViewBuilder private func relGroup(_ title: String, _ list: [Entry]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
                SectionHeader("\(title) (\(list.count))")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list.prefix(30)) { e in
                        RelationRow(title: e.title ?? e.path) { Task { await model.open(e.path) } }
                    }
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
            Text(title)
                .font(Typo.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4)
                .frame(minHeight: InspectorStyle.rowHeight)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: InspectorStyle.rowCorner)
                .fill(.quaternary)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}
