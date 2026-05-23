import SwiftUI
import MarpleKit

/// Ulysses-style right inspector: one scrollable panel stacking 统计 / 信息 / 目录,
/// with a top icon strip that jumps to a section.
struct InspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 22) {
                    iconButton("chart.bar", "stats", proxy)
                    iconButton("list.bullet.rectangle", "info", proxy)
                    iconButton("list.number", "outline", proxy)
                }
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        StatsSection(stats: model.openStats).id("stats")
                        InfoSection(model: model).id("info")
                        OutlineSection(model: model).id("outline")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func iconButton(_ symbol: String, _ anchor: String, _ proxy: ScrollViewProxy) -> some View {
        Button { withAnimation { proxy.scrollTo(anchor, anchor: .top) } } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Shared bits

private struct SectionHeader: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        Text(title).font(.caption).fontWeight(.semibold)
            .foregroundStyle(.secondary).textCase(.uppercase)
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
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("目录")
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6, alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(themes, id: \.self) { t in
                        HStack(spacing: 3) {
                            Button(t) { model.select(pane: .theme(t)) }.buttonStyle(.plain)
                            Button { Task { await model.removeTheme(t) } } label: {
                                Image(systemName: "xmark").font(.system(size: 8))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
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
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader("\(title) (\(list.count))")
                ForEach(list.prefix(30)) { e in
                    Button { Task { await model.open(e.path) } } label: {
                        Text(e.title ?? e.path).font(.callout).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
