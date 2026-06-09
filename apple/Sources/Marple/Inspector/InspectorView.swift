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
    static let metadataChipMaxWidth: CGFloat = 160
    static let rowHeight: CGFloat = 26
    static let rowCorner: CGFloat = 7
    static let markerSize: CGFloat = 9
    static let outlineIndent: CGFloat = 16

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
            value
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: InspectorStyle.rowHeight)
    }
}

private struct MarkerRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: "circle")
                .font(.system(size: InspectorStyle.markerSize, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            content
        }
        .frame(minHeight: InspectorStyle.rowHeight)
    }
}

/// Auxiliary conformance flag: lists the required frontmatter fields this entry's
/// canonical type is missing, per the vault's `.quasi/schema.json`. Only rendered
/// when a snapshot exists AND the entry is non-conforming — otherwise the caller
/// shows nothing, so the inspector is byte-identical to a vault with no snapshot.
private struct ConformanceBanner: View {
    let missing: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: InspectorStyle.markerSize, weight: .medium))
                .foregroundStyle(.orange)
            Text("缺少必填：" + missing.map(conformanceFieldLabel).joined(separator: "、"))
                .font(Typo.caption)
                .foregroundStyle(InspectorStyle.rowLabelColor)
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
            if let topic = model.openTopic {
                TopicNavGroup(model: model, topic: topic)
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

/// EPUB-style "本专题" navigation: the topic's overview + its resources pages,
/// mirroring BookNavGroup. Topic pages share one type and are split by `kind`
/// (see TopicContext), so the same overview-plus-children affordance applies.
private struct TopicNavGroup: View {
    @Bindable var model: AppModel
    let topic: TopicContext
    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
            SectionHeader("本专题")
            VStack(alignment: .leading, spacing: 0) {
                if let ov = topic.overview {
                    BookNavRow(label: "概述",
                               active: model.openPath == ov.path) { navigate(to: ov.path) }
                }
                ForEach(topic.pages) { page in
                    BookNavRow(label: pageLabel(page),
                               active: model.openPath == page.path) { navigate(to: page.path) }
                }
            }
        }
    }

    private func navigate(to path: String) {
        guard path != model.openPath else { return }
        Task { await model.open(path) }
    }

    private func pageLabel(_ e: Entry) -> String {
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
                let minLevel = model.openOutline.map(\.level).min() ?? 1
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.openOutline) { item in
                        PageOutlineRow(item: item, depth: item.level - minLevel) {
                            model.scrollTarget = item.blockIndex
                        }
                    }
                }
            }
        }
    }
}

private struct PageOutlineRow: View {
    let item: OutlineItem
    let depth: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            MarkerRow {
                Text(item.text)
                    .font(Typo.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: InspectorStyle.rowCorner)
                .fill(.quaternary)
                .padding(.horizontal, -Space.s4)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .padding(.leading, CGFloat(depth) * InspectorStyle.outlineIndent)
    }
}

// MARK: - 信息

private struct InfoSection: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.sectionSpacing) {
            if let e = model.openEntry {
                VStack(alignment: .leading, spacing: InspectorStyle.headerSpacing) {
                    SectionHeader("信息")
                    if let err = model.writeError {
                        Text("保存失败：\(err)").font(.caption).foregroundStyle(.red)
                    }
                    if let result = model.conformance(for: e), !result.isConforming {
                        ConformanceBanner(missing: result.missingRequired)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        InspectorInfoRowsView(model: model, entry: e)
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

private struct InspectorInfoRowsView: View {
    @Bindable var model: AppModel
    let entry: Entry

    var body: some View {
        ForEach(Array(inspectorInfoRows(for: entry, in: model.entries, localise: model.localisation).enumerated()), id: \.offset) { _, row in
            switch row {
            case .rating:
                RatingRow(model: model, score: Int(entry.ratingScore))
            case .authors:
                AuthorRow(model: model, entry: entry)
            case .editableScalar(let label, let value, let action):
                ScalarRow(model: model, label: label, value: value) { await commit($0, action: action) }
            case .readOnlyScalar(let label, let value, let copyValue):
                ReadOnlyScalarRow(label: label, value: value, copyValue: copyValue)
            case .linkedScalar(let label, let value, let path, let copyValue):
                MetadataChipsRow(
                    label: label,
                    values: [InspectorInfoChip(title: value, path: path, copyValue: copyValue)]
                ) { target in
                    openInspectorTarget(target, model: model)
                }
            case .chips(let label, let values):
                MetadataChipsRow(label: label, values: values) { target in
                    openInspectorTarget(target, model: model)
                }
            case .identifier(let label, let displayValue, let fullValue):
                ReadOnlyScalarRow(label: label, value: displayValue, copyValue: fullValue)
            }
        }
    }

    private func commit(_ value: String?, action: MetadataAction) async {
        switch action {
        case .title:
            await model.setTitle(value)
        case .year:
            await model.setYear(value)
        case .imageAuthor:
            await model.setAuthor(splitAuthors(value))
        case .source:
            await model.setSource(value)
        case .doi:
            await model.setDoi(value)
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
                    .frame(maxWidth: .infinity, alignment: .trailing)
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

private struct ReadOnlyScalarRow: View {
    let label: String
    let value: String
    var copyValue: String? = nil

    var body: some View {
        FieldRow(label) {
            Text(value)
                .font(Typo.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(copyValue ?? value)
                .contextMenu {
                    Button("复制") { copy(copyValue ?? value) }
                }
        }
    }
}

private struct MetadataChipsRow: View {
    let label: String
    let values: [InspectorInfoChip]
    let onTap: (String) -> Void

    var body: some View {
        FieldRow(label) {
            TrailingFlowLayout(spacing: Space.s2, lineSpacing: Space.s2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    MetadataChip(value: value) { path in onTap(path) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct TrailingFlowLayout: Layout {
    var spacing: CGFloat = Space.s2
    var lineSpacing: CGFloat = Space.s2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth.isFinite ? maxWidth : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.maxX - row.width
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.width, height: item.height)
                )
                x += item.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item { var index: Int; var width: CGFloat; var height: CGFloat }
    private struct Row { var items: [Item] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let remaining = maxWidth.isFinite ? maxWidth : InspectorStyle.metadataChipMaxWidth
            let proposedWidth = min(remaining, InspectorStyle.metadataChipMaxWidth)
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            let item = Item(index: index, width: min(size.width, proposedWidth), height: size.height)
            let projected = current.items.isEmpty ? item.width : current.width + spacing + item.width
            if !current.items.isEmpty, projected > maxWidth {
                rows.append(current)
                current = Row(items: [item], width: item.width, height: item.height)
            } else {
                current.width = current.items.isEmpty ? item.width : current.width + spacing + item.width
                current.items.append(item)
                current.height = max(current.height, item.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

private struct MetadataChip: View {
    let value: InspectorInfoChip
    let onTap: (String) -> Void

    var body: some View {
        Group {
            if let path = value.path {
                Button { onTap(path) } label: { chipText }
                    .buttonStyle(.plain)
            } else {
                chipText
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .help(value.copyValue ?? value.title)
        .contextMenu {
            if let path = value.path {
                Button("跳转到 \(value.title)") { onTap(path) }
            }
            Button("复制") { copy(value.copyValue ?? value.title) }
        }
    }

    private var chipText: some View {
        Text(value.title)
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

/// Resolve a metadata chip tap: external http(s) URLs (e.g. a 译本 Douban link)
/// open in the browser; everything else is an internal vault path.
private func openInspectorTarget(_ target: String, model: AppModel) {
    if (target.hasPrefix("http://") || target.hasPrefix("https://")),
       let url = URL(string: target) {
        NSWorkspace.shared.open(url)
    } else {
        Task { await model.open(target) }
    }
}

private struct AuthorRow: View {
    @Bindable var model: AppModel
    let entry: Entry
    @State private var droppedCount = 0
    @State private var listOpen = false
    @State private var editingIndex: Int? = nil
    @State private var editingAll = false

    /// Talks store presenters under `speaker:`, so label this row 讲者 for them.
    private var noun: String { entry.type == .talk ? "讲者" : "作者" }

    var body: some View {
        FieldRow(noun) {
            let names = entry.author
            if names.isEmpty {
                // Empty-state affordance so the user can re-add authors after
                // clearing all chips. Without this, the row would render empty
                // and the bulk editor (popover below) would have no anchor.
                Button {
                    editingAll = true
                } label: {
                    Label("添加\(noun)", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if names.count == 1, let name = names.first {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    chip(name: name, index: 0, names: names)
                }
            } else {
                SingleLineOverflowLayout(droppedCount: $droppedCount, spacing: Space.s2) {
                    ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                        chip(name: name, index: i, names: names)
                    }
                    Button("+\(droppedCount > 0 ? droppedCount : max(1, names.count - 1))") {
                        listOpen = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .popover(isPresented: $listOpen, arrowEdge: .top) {
                        AuthorListPopover(
                            names: names,
                            profile: { model.authorProfile(for: $0) },
                            onTap: { e in
                                listOpen = false
                                Task { await model.open(e.path) }
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        // Bulk editor lives in a popover (not inline) so the multi-line
        // TextEditor doesn't blow out the inspector's narrow column.
        .popover(isPresented: $editingAll, arrowEdge: .top) {
            FullAuthorEditor(initial: entry.author.joined(separator: "\n")) { newValue in
                Task {
                    let parsed: [String] = newValue
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    await model.setAuthor(parsed)
                    editingAll = false
                }
            } onCancel: { editingAll = false }
        }
        .id(entry.path)
    }

    @ViewBuilder
    private func chip(name: String, index: Int, names: [String]) -> some View {
        AuthorChip(
            name: name,
            profile: model.authorProfile(for: name),
            onTap: { e in Task { await model.open(e.path) } },
            onEdit: { editingIndex = index },
            onRemove: { Task { await spliceAuthor(at: index, with: nil, names: names) } },
            onEditAll: { editingAll = true }
        )
        .popover(
            isPresented: Binding(
                get: { editingIndex == index },
                set: { if !$0 { editingIndex = nil } }
            ),
            arrowEdge: .top
        ) {
            ChipEditor(initial: name) { newName in
                Task {
                    await spliceAuthor(at: index, with: newName, names: names)
                    editingIndex = nil
                }
            } onCancel: { editingIndex = nil }
        }
    }

    /// Splice the names list (replace or delete at `index`) and commit via
    /// `setAuthor`. Lossless since QUA-109 — the model now stores `[String]`
    /// directly, no string serialization in the middle.
    private func spliceAuthor(at index: Int, with newName: String?, names: [String]) async {
        var updated = names
        let trimmed = newName?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty {
            updated[index] = trimmed
        } else {
            updated.remove(at: index)
        }
        await model.setAuthor(updated)
    }
}

private struct AuthorChip: View {
    let name: String
    let profile: Entry?
    let onTap: (Entry) -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onEditAll: () -> Void

    var body: some View {
        Group {
            if let p = profile {
                Button(name) { onTap(p) }.buttonStyle(.plain)
            } else {
                Text(name)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .lineLimit(1)
        .truncationMode(.head)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .contextMenu {
            if let p = profile {
                Button("跳转到 \(name)") { onTap(p) }
            }
            Button("编辑此作者名…") { onEdit() }
            Button("从此条目移除", role: .destructive) { onRemove() }
            Button("复制") { copy(name) }
            Divider()
            Button("编辑全部作者…") { onEditAll() }
        }
    }
}

private struct AuthorListPopover: View {
    let names: [String]
    let profile: (String) -> Entry?
    let onTap: (Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(names, id: \.self) { name in
                let p = profile(name)
                Button { if let p { onTap(p) } } label: {
                    HStack(spacing: 8) {
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 8)
                        if p != nil {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(minWidth: 180, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(p == nil)
            }
        }
        .padding(4)
    }
}

private struct ChipEditor: View {
    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("作者姓名", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .focused($focused)
                .onSubmit { onCommit(draft) }
                .onExitCommand { onCancel() }
            HStack(spacing: 8) {
                Button("取消") { onCancel() }
                Button("保存") { onCommit(draft) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { draft = initial; focused = true }
    }
}

/// Bulk editor for the author list — one name per line. Renders inside a
/// popover (anchored to the AuthorRow) with a fixed width so the multi-line
/// TextEditor doesn't disturb the inspector's narrow trailing column.
///
/// Comma-bearing names like "Smith, John Jr." (Last, First) stay one author
/// because the only line-delimiter is `\n`.
private struct FullAuthorEditor: View {
    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $draft)
                .font(Typo.callout)
                .frame(width: 240, height: 110)
                .padding(4)
                .background(.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.tertiary, lineWidth: 0.5)
                )
                .focused($focused)
                .onExitCommand { onCancel() }
                .onAppear { draft = initial; focused = true }
            HStack(spacing: 8) {
                Text("每行一位作者")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("取消") { onCancel() }
                Button("保存") { onCommit(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// Lays subviews on a single line; the *last* subview is the overflow indicator
/// and is only placed when earlier subviews don't all fit. We reserve a fixed
/// 36 pt slot for it so its text width (which depends on the dropped count) does
/// not feed back into the layout and cause oscillation.
private struct SingleLineOverflowLayout: Layout {
    @Binding var droppedCount: Int
    var spacing: CGFloat = Space.s2
    private let moreReserveWidth: CGFloat = 36

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        // We deliberately do NOT report dropped from here: SwiftUI calls
        // sizeThatFits speculatively with proposal.width == .infinity, which
        // would race with the real placement pass and oscillate the state.
        let width = proposal.width ?? .infinity
        let plan = compute(width: width, subviews: subviews)
        return CGSize(width: width.isFinite ? width : plan.usedWidth, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let plan = compute(width: bounds.width, subviews: subviews)
        report(dropped: plan.dropped)
        let placed = Set(plan.placements.map(\.idx))
        // Right-align the chip block within bounds, matching how other
        // FieldRow values (year, source) sit on the trailing edge.
        let shift = bounds.width - plan.usedWidth
        for p in plan.placements {
            let s = subviews[p.idx].sizeThatFits(.unspecified)
            let y = bounds.minY + (bounds.height - s.height) / 2
            subviews[p.idx].place(at: CGPoint(x: bounds.minX + shift + p.x, y: y),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(s))
        }
        for i in 0..<subviews.count where !placed.contains(i) {
            subviews[i].place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY),
                              anchor: .topLeading,
                              proposal: .zero)
        }
    }

    private struct Plan {
        var placements: [(idx: Int, x: CGFloat)] = []
        var usedWidth: CGFloat = 0
        var height: CGFloat = 0
        var dropped: Int = 0
    }

    private func compute(width: CGFloat, subviews: Subviews) -> Plan {
        let moreIdx = subviews.count - 1
        let chipCount = moreIdx
        guard chipCount > 0 else { return Plan() }

        var plan = Plan()
        var x: CGFloat = 0
        var visible = 0

        for i in 0..<chipCount {
            let s = subviews[i].sizeThatFits(.unspecified)
            let advanceX = visible == 0 ? s.width : x + spacing + s.width
            let needsMoreAfter = (i < chipCount - 1)
            let reserve = needsMoreAfter ? (spacing + moreReserveWidth) : 0
            // Always place the first chip — a row showing only "+N" with no
            // visible author tells the user nothing useful.
            if visible > 0, advanceX + reserve > width { break }
            let placeAt = visible == 0 ? 0 : x + spacing
            plan.placements.append((i, placeAt))
            plan.height = max(plan.height, s.height)
            x = advanceX
            visible += 1
        }

        let dropped = chipCount - visible
        if dropped > 0 {
            let moreSize = subviews[moreIdx].sizeThatFits(.unspecified)
            let placeAt = visible == 0 ? 0 : x + spacing
            plan.placements.append((moreIdx, placeAt))
            plan.usedWidth = placeAt + moreSize.width
            plan.height = max(plan.height, moreSize.height)
        } else {
            plan.usedWidth = x
        }
        plan.dropped = dropped
        return plan
    }

    private func report(dropped: Int) {
        guard dropped != droppedCount else { return }
        Task { @MainActor in
            if dropped != droppedCount { droppedCount = dropped }
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
                SectionHeader("标签")
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
                .help(adding ? "取消" : "添加标签")
                .onHover { hoveringAdd = $0 }
            }
            if themes.isEmpty {
                Button { adding = true } label: {
                    Text("添加标签")
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
                TextField("新标签（逗号分隔可多个）", text: $draft)
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
                    let books = r.works.filter { $0.type == .book }
                    let papers = r.works.filter { $0.type == .paper }
                    relGroup("图书", books)
                    relGroup("论文", papers)
                }
                relGroup("专题成员", r.topicMembers)
                let siblingBooks = r.siblings.filter { $0.type == .book }
                let siblingPapers = r.siblings.filter { $0.type == .paper }
                relGroup("同作者专著", siblingBooks)
                relGroup("同作者论文", siblingPapers)
                relGroup("同标签相似", r.similar)
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
            MarkerRow {
                Text(title)
                    .font(Typo.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: InspectorStyle.rowCorner)
                .fill(.quaternary)
                .padding(.horizontal, -Space.s4)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}
