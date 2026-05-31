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
        switch model.pane {
        case .type(let t):   return "\(t.label) (\(model.visibleEntries.count))"
        case .theme(let n):  return "标签: \(n) (\(model.visibleEntries.count))"
        case .themesIndex:   return "标签"
        case .trash:         return "回收站"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SearchField(model: model)
            sortButton
            filterButton
        }
        .padding(8)
        .disabled(isThemesIndex)   // header is meaningless on the themes index pane
        .opacity(isThemesIndex ? 0.4 : 1)
    }

    private var isThemesIndex: Bool { if case .themesIndex = model.pane { return true } else { return false } }

    private var sortButton: some View {
        Button { showingSorts.toggle() } label: {
            Image(systemName: model.sortClauses.isEmpty ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .popover(isPresented: $showingSorts, arrowEdge: .top) {
            SortPopover(model: model)
        }
    }

    private var filterButton: some View {
        Button { showingFilters.toggle() } label: {
            Image(systemName: model.filterClauses.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
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

            if model.sortClauses.isEmpty {
                Text("默认顺序")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.sortClauses.enumerated()), id: \.offset) { index, clause in
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
                if !model.sortClauses.isEmpty {
                    Button("恢复默认") { model.setSort([]) }
                }
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 292)
    }

    private var unusedSortFields: [SortField] {
        let used = Set(model.sortClauses.map(\.field))
        return SortField.allCases.filter { !used.contains($0) }
    }

    private func addSort() {
        guard let field = unusedSortFields.first else { return }
        model.setSort(model.sortClauses + [SortClause(field: field, dir: field.defaultDir)])
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
                    Text(field.label).tag(field)
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
                    .disabled(index >= model.sortClauses.count - 1)
                Button { remove() } label: { Image(systemName: "xmark") }
            }
            .foregroundStyle(.secondary)
        }
        .frame(height: 26)
        .buttonStyle(.borderless)
    }

    private var current: SortClause {
        guard model.sortClauses.indices.contains(index) else { return clause }
        return model.sortClauses[index]
    }

    private var fieldBinding: Binding<SortField> {
        Binding(get: { current.field }, set: { updateField($0) })
    }

    private var dirBinding: Binding<SortDir> {
        Binding(get: { current.dir }, set: { updateDir($0) })
    }

    private var availableFields: [SortField] {
        let usedElsewhere = Set(model.sortClauses.enumerated().compactMap { item in
            item.offset == index ? nil : item.element.field
        })
        return SortField.allCases.filter { $0 == current.field || !usedElsewhere.contains($0) }
    }

    private func updateField(_ field: SortField) {
        guard model.sortClauses.indices.contains(index),
              availableFields.contains(field),
              current.field != field else { return }
        var next = model.sortClauses
        next[index] = SortClause(field: field, dir: field.defaultDir)
        model.setSort(next)
    }

    private func updateDir(_ dir: SortDir) {
        guard model.sortClauses.indices.contains(index),
              current.dir != dir else { return }
        var next = model.sortClauses
        next[index] = SortClause(field: next[index].field, dir: dir)
        model.setSort(next)
    }

    private func move(by delta: Int) {
        let target = index + delta
        guard model.sortClauses.indices.contains(index), model.sortClauses.indices.contains(target) else { return }
        var next = model.sortClauses
        next.swapAt(index, target)
        model.setSort(next)
    }

    private func remove() {
        guard model.sortClauses.indices.contains(index) else { return }
        var next = model.sortClauses
        next.remove(at: index)
        model.setSort(next)
    }
}

private struct FilterPopover: View {
    let model: AppModel

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

            if model.filterClauses.isEmpty {
                Text("还没有筛选条件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.filterClauses) { clause in
                        FilterClauseRow(model: model, clauseID: clause.id, fallback: clause)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button { addFilter() } label: {
                    Label("添加筛选", systemImage: "plus")
                }
                Spacer()
                if !model.filterClauses.isEmpty {
                    Button("清空") { model.setFilters([], match: model.filterMatch) }
                }
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 380)
    }

    private var matchBinding: Binding<FilterMatch> {
        Binding(
            get: { model.filterMatch },
            set: {
                guard $0 != model.filterMatch else { return }
                model.setFilters(model.filterClauses, match: $0)
            }
        )
    }

    private func addFilter() {
        model.setFilters(model.filterClauses + [defaultFilterClause(for: .rating)], match: model.filterMatch)
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
                    Text(field.label).tag(field)
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
            } else {
                TextField(filterPlaceholder(for: current.field), text: valueBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 112)
            }

            if !clauseReady(current) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.tertiary)
                    .help("条件未完整，暂不生效")
            }

            Spacer(minLength: 2)

            Button { remove() } label: { Image(systemName: "xmark") }
                .foregroundStyle(.secondary)
        }
        .frame(height: 28)
        .buttonStyle(.borderless)
    }

    private var current: FilterClause {
        model.filterClauses.first { $0.id == clauseID } ?? fallback
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
        guard let index = model.filterClauses.firstIndex(where: { $0.id == clauseID }),
              current.field != field else { return }
        var next = model.filterClauses
        next[index] = defaultFilterClause(for: field, id: clauseID)
        model.setFilters(next, match: model.filterMatch)
    }

    private func updateOp(_ op: FilterOp) {
        guard let index = model.filterClauses.firstIndex(where: { $0.id == clauseID }),
              currentOp != op else { return }
        var next = model.filterClauses
        next[index].op = op
        model.setFilters(next, match: model.filterMatch)
    }

    private func updateValue(_ value: String) {
        guard let index = model.filterClauses.firstIndex(where: { $0.id == clauseID }),
              current.value != value else { return }
        var next = model.filterClauses
        next[index].value = value
        model.setFilters(next, match: model.filterMatch)
    }

    private func remove() {
        let next = model.filterClauses.filter { $0.id != clauseID }
        model.setFilters(next, match: model.filterMatch)
    }
}

private func filterOps(for field: FilterField) -> [FilterOp] {
    switch field {
    case .rating, .year: return [.gte, .lte, .eq]
    case .author: return [.contains]
    case .theme, .source: return [.contains, .is_]
    case .haspdf: return [.yes]
    case .added: return [.within]
    }
}

private func filterOpLabel(_ op: FilterOp, for field: FilterField) -> String {
    switch op {
    case .gte: return "≥"
    case .lte: return "≤"
    case .eq: return "="
    case .contains: return "包含"
    case .is_: return "是"
    case .yes: return field == .haspdf ? "有" : "是"
    case .within: return "近"
    }
}

private func filterPlaceholder(for field: FilterField) -> String {
    switch field {
    case .rating: return "分数"
    case .year: return "年份"
    case .author: return "作者"
    case .theme: return "标签"
    case .source: return "来源"
    case .haspdf: return ""
    case .added: return "天数"
    }
}

private func defaultFilterClause(for field: FilterField, id: String = UUID().uuidString) -> FilterClause {
    switch field {
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
