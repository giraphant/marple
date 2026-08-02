import SwiftUI
import MarpleKit

struct EntryListView: View {
    let model: AppModel
    @State private var showingSorts = false
    @State private var showingFilters = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Why not SwiftUI `List`: see EntryListTable header. tl;dr — Ulysses
            // pale-blue sourceList selection needs `NSTableView` directly, and
            // SwiftUI List's internal table triggers the QUA-103 reentrant
            // delegate warning that we can't silence from outside.
            EntryListTable(model: model)
        }
        .navigationTitle(title)
    }

    private var title: String {
        if model.isPinnedListContext {
            return "固定页面 (\(model.visibleEntries.count))"
        }
        switch model.pane {
        case .type(let type):
            return String(localized: "\(AppPresentation.entryTypeLabel(type)) (\(model.visibleEntries.count))")
        case .theme(let name):
            return String(localized: "标签：\(name) (\(model.visibleEntries.count))")
        case .themesIndex:
            return String(localized: "标签")
        case .trash:
            return String(localized: "回收站")
        case .savedView(let id):
            return String(localized: "\(model.savedView(id)?.name ?? String(localized: "视图")) (\(model.visibleEntries.count))")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SearchField(model: model)
            if !model.isPinnedListContext {
                sortButton
                filterButton
                gridToggle
            }
        }
        .padding(8)
        .disabled(isThemesIndex)   // header is meaningless on the themes index pane
        .opacity(isThemesIndex ? 0.4 : 1)
    }

    private var isThemesIndex: Bool { if case .themesIndex = model.pane { return true } else { return false } }

    /// Switch to the grid lab (QUA-114). The app had no list/grid toggle at all;
    /// browseMode was only ever restored from persisted state.
    private var gridToggle: some View {
        Button { model.browseMode = .grid } label: {
            Image(systemName: "square.grid.2x2")
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(String(localized: "切换到网格"))
    }

    private var sortButton: some View {
        Button { showingSorts.toggle() } label: {
            Image(systemName: model.activeSortClauses.isEmpty ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .popover(isPresented: $showingSorts, arrowEdge: .top) {
            SortPopover(model: model)
        }
    }

    private var filterButton: some View {
        Button { showingFilters.toggle() } label: {
            Image(systemName: model.activeFilterClauses.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .popover(isPresented: $showingFilters, arrowEdge: .top) {
            FilterPopover(model: model)
        }
    }
}

private struct SortPopover: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("排序")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.activeSortClauses.isEmpty {
                Text("默认顺序")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.activeSortClauses.enumerated()), id: \.offset) { index, clause in
                        SortClauseRow(model: model, index: index, clause: clause)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button { addSort() } label: {
                    Label("添加排序", systemImage: "plus")
                }
                .disabled(unusedSortFields.isEmpty)
                Spacer()
                if !model.activeSortClauses.isEmpty {
                    Button("恢复默认") { model.setSort([]) }
                }
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 292)
    }

    private var unusedSortFields: [SortField] {
        let used = Set(model.activeSortClauses.map(\.field))
        return SortField.allCases.filter { !used.contains($0) }
    }

    private func addSort() {
        guard let field = unusedSortFields.first else { return }
        model.setSort(model.activeSortClauses + [SortClause(field: field, dir: field.defaultDir)])
    }
}

private struct SortClauseRow: View {
    let model: AppModel
    let index: Int
    let clause: SortClause

    var body: some View {
        HStack(spacing: 7) {
            Picker("字段", selection: fieldBinding) {
                ForEach(availableFields, id: \.self) { field in
                    Text(AppPresentation.sortFieldLabel(field)).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 92)

            Picker("方向", selection: dirBinding) {
                Text("升序").tag(SortDir.asc)
                Text("降序").tag(SortDir.desc)
            }
            .labelsHidden()
            .frame(width: 68)

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index >= model.activeSortClauses.count - 1)
                Button { remove() } label: { Image(systemName: "xmark") }
            }
            .foregroundStyle(.secondary)
        }
        .frame(height: 26)
        .buttonStyle(.borderless)
    }

    private var current: SortClause {
        guard model.activeSortClauses.indices.contains(index) else { return clause }
        return model.activeSortClauses[index]
    }

    private var fieldBinding: Binding<SortField> {
        Binding(get: { current.field }, set: { updateField($0) })
    }

    private var dirBinding: Binding<SortDir> {
        Binding(get: { current.dir }, set: { updateDir($0) })
    }

    private var availableFields: [SortField] {
        let usedElsewhere = Set(model.activeSortClauses.enumerated().compactMap { item in
            item.offset == index ? nil : item.element.field
        })
        return SortField.allCases.filter { $0 == current.field || !usedElsewhere.contains($0) }
    }

    private func updateField(_ field: SortField) {
        guard model.activeSortClauses.indices.contains(index),
              availableFields.contains(field),
              current.field != field else { return }
        var next = model.activeSortClauses
        next[index] = SortClause(field: field, dir: field.defaultDir)
        model.setSort(next)
    }

    private func updateDir(_ dir: SortDir) {
        guard model.activeSortClauses.indices.contains(index),
              current.dir != dir else { return }
        var next = model.activeSortClauses
        next[index] = SortClause(field: next[index].field, dir: dir)
        model.setSort(next)
    }

    private func move(by delta: Int) {
        let target = index + delta
        guard model.activeSortClauses.indices.contains(index), model.activeSortClauses.indices.contains(target) else { return }
        var next = model.activeSortClauses
        next.swapAt(index, target)
        model.setSort(next)
    }

    private func remove() {
        guard model.activeSortClauses.indices.contains(index) else { return }
        var next = model.activeSortClauses
        next.remove(at: index)
        model.setSort(next)
    }
}

private struct FilterPopover: View {
    let model: AppModel
    @State private var namingView = false
    @State private var newViewName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("满足")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: matchBinding) {
                    Text("全部").tag(FilterMatch.all)
                    Text("任一").tag(FilterMatch.any)
                }
                .pickerStyle(.segmented)
                .frame(width: 112)
                Text("条件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.activeFilterClauses.isEmpty {
                Text("还没有筛选条件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.activeFilterClauses) { clause in
                        FilterClauseRow(model: model, clauseID: clause.id, fallback: clause)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button { addFilter() } label: {
                    Label("添加筛选", systemImage: "plus")
                }
                Button("存为视图…") {
                    newViewName = ""
                    namingView = true
                }
                .disabled(!canSaveView)
                .help(String(localized: "把当前筛选和排序固定为侧栏里的一个视图"))
                Spacer()
                if !model.activeFilterClauses.isEmpty {
                    Button("清空") { model.setFilters([], match: model.activeFilterMatch) }
                }
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 380)
        .alert("存为视图", isPresented: $namingView) {
            TextField("视图名称", text: $newViewName)
            Button("保存") {
                let name = newViewName.trimmingCharacters(in: .whitespacesAndNewlines)
                model.createSavedView(named: name.isEmpty ? String(localized: "新视图") : name)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前的筛选和排序会固定为侧栏「视图」里的一项。")
        }
    }

    /// Saving makes sense when the snapshot would carry at least one clause —
    /// either a completed filter, or the bucket itself (createSavedView injects
    /// `类型/标签 是 X` for a bucket under 全部-match). Mirrors that injection
    /// rule so the button never mints an empty match-everything view.
    private var canSaveView: Bool {
        if model.activeFilterClauses.contains(where: clauseReady) { return true }
        guard model.activeFilterMatch == .all else { return false }
        switch model.pane {
        case .type, .theme: return true
        default: return false
        }
    }

    private var matchBinding: Binding<FilterMatch> {
        Binding(
            get: { model.activeFilterMatch },
            set: {
                guard $0 != model.activeFilterMatch else { return }
                model.setFilters(model.activeFilterClauses, match: $0)
            }
        )
    }

    private func addFilter() {
        model.setFilters(model.activeFilterClauses + [defaultFilterClause(for: .rating)], match: model.activeFilterMatch)
    }
}

private struct FilterClauseRow: View {
    let model: AppModel
    let clauseID: String
    let fallback: FilterClause

    var body: some View {
        HStack(spacing: 7) {
            Picker("字段", selection: fieldBinding) {
                ForEach(FilterField.allCases, id: \.self) { field in
                    Text(AppPresentation.filterFieldLabel(field)).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 78)

            if filterOps(for: current.field).count > 1 {
                Picker("条件", selection: opBinding) {
                    ForEach(filterOps(for: current.field), id: \.self) { op in
                        Text(filterOpLabel(op, for: current.field)).tag(op)
                    }
                }
                .labelsHidden()
                .frame(width: 62)
            } else {
                Text(filterOpLabel(currentOp, for: current.field))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
            }

            if current.field.input == .none {
                Text("是")
                    .foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .leading)
            } else if current.field.input == .choice {
                Picker("类型", selection: valueBinding) {
                    ForEach(filterTypeOptions, id: \.rawValue) { type in
                        Text(AppPresentation.entryTypeLabel(type)).tag(type.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
            } else {
                TextField(filterPlaceholder(for: current.field), text: valueBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 112)
            }

            if !clauseReady(current) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.tertiary)
                    .help(String(localized: "条件未完整，暂不生效"))
            }

            Spacer(minLength: 2)

            Button { remove() } label: { Image(systemName: "xmark") }
                .foregroundStyle(.secondary)
        }
        .frame(height: 28)
        .buttonStyle(.borderless)
    }

    private var current: FilterClause {
        model.activeFilterClauses.first { $0.id == clauseID } ?? fallback
    }

    private var currentOp: FilterOp {
        let ops = filterOps(for: current.field)
        return ops.contains(current.op) ? current.op : ops[0]
    }

    private var fieldBinding: Binding<FilterField> {
        Binding(get: { current.field }, set: { updateField($0) })
    }

    private var opBinding: Binding<FilterOp> {
        Binding(get: { currentOp }, set: { updateOp($0) })
    }

    private var valueBinding: Binding<String> {
        Binding(get: { current.value }, set: { updateValue($0) })
    }

    private func updateField(_ field: FilterField) {
        guard let index = model.activeFilterClauses.firstIndex(where: { $0.id == clauseID }),
              current.field != field else { return }
        var next = model.activeFilterClauses
        next[index] = defaultFilterClause(for: field, id: clauseID)
        model.setFilters(next, match: model.activeFilterMatch)
    }

    private func updateOp(_ op: FilterOp) {
        guard let index = model.activeFilterClauses.firstIndex(where: { $0.id == clauseID }),
              currentOp != op else { return }
        var next = model.activeFilterClauses
        next[index].op = op
        model.setFilters(next, match: model.activeFilterMatch)
    }

    private func updateValue(_ value: String) {
        guard let index = model.activeFilterClauses.firstIndex(where: { $0.id == clauseID }),
              current.value != value else { return }
        var next = model.activeFilterClauses
        next[index].value = value
        model.setFilters(next, match: model.activeFilterMatch)
    }

    private func remove() {
        let next = model.activeFilterClauses.filter { $0.id != clauseID }
        model.setFilters(next, match: model.activeFilterMatch)
    }
}

private func filterOps(for field: FilterField) -> [FilterOp] {
    switch field {
    case .type: return [.is_]
    case .rating, .year: return [.gte, .lte, .eq]
    case .author: return [.contains]
    case .theme, .source: return [.contains, .is_]
    case .haspdf: return [.yes]
    case .added: return [.within]
    }
}

/// Options for the 类型 value picker. `modeled` plus `transcript` — a transcript
/// is indexed but deliberately has no sidebar bucket, which makes a saved view
/// the only browse surface for it.
private let filterTypeOptions: [EntryType] = EntryType.modeled + [.transcript]

private func filterOpLabel(_ op: FilterOp, for field: FilterField) -> String {
    switch op {
    case .gte: return "≥"
    case .lte: return "≤"
    case .eq: return "="
    case .contains: return String(localized: "包含")
    case .is_: return String(localized: "是")
    case .yes: return field == .haspdf ? String(localized: "有") : String(localized: "是")
    case .within: return String(localized: "近")
    }
}

private func filterPlaceholder(for field: FilterField) -> String {
    switch field {
    case .type: return ""
    case .rating: return String(localized: "分数")
    case .year: return String(localized: "年份")
    case .author: return String(localized: "作者")
    case .theme: return String(localized: "标签")
    case .source: return String(localized: "来源")
    case .haspdf: return ""
    case .added: return String(localized: "天数")
    }
}

private func defaultFilterClause(for field: FilterField, id: String = UUID().uuidString) -> FilterClause {
    switch field {
    case .type: return FilterClause(id: id, field: .type, op: .is_, value: EntryType.paper.rawValue)
    case .rating: return FilterClause(id: id, field: .rating, op: .gte, value: "3")
    case .year: return FilterClause(id: id, field: .year, op: .gte, value: "")
    case .author: return FilterClause(id: id, field: .author, op: .contains, value: "")
    case .theme: return FilterClause(id: id, field: .theme, op: .contains, value: "")
    case .source: return FilterClause(id: id, field: .source, op: .contains, value: "")
    case .haspdf: return FilterClause(id: id, field: .haspdf, op: .yes, value: "")
    case .added: return FilterClause(id: id, field: .added, op: .within, value: "30")
    }
}

/// Isolated search field: reading `searchText` here means typing only invalidates
/// this small view, not the entry `List` — so keystrokes never re-render the
/// (potentially ~11k row) results list (mirrors CodeEdit's query/results split).
private struct SearchField: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索", text: Binding(
                get: { model.searchText },
                set: { model.setSearchText($0) }
            ))
            .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button { model.setSearchText("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
