import SwiftUI
import MarpleKit

struct EntryListView: View {
    @Bindable var model: AppModel

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
        case .theme(let n):  return "主题: \(n) (\(model.visibleEntries.count))"
        case .themesIndex:   return "主题"
        case .trash:         return "回收站"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SearchField(model: model)
            sortMenu
            filterMenu
        }
        .padding(8)
        .disabled(isThemesIndex)   // header is meaningless on the themes index pane
        .opacity(isThemesIndex ? 0.4 : 1)
    }

    private var isThemesIndex: Bool { if case .themesIndex = model.pane { return true } else { return false } }

    private var sortMenu: some View {
        Menu {
            Button("默认顺序") { model.setSort([]) }
            Divider()
            ForEach(SortField.allCases, id: \.self) { f in
                Menu(f.label) {
                    Button("升序 ↑") { model.setSort([SortClause(field: f, dir: .asc)]) }
                    Button("降序 ↓") { model.setSort([SortClause(field: f, dir: .desc)]) }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var filterMenu: some View {
        Menu {
            Button("清除筛选") { model.setFilters([]) }
            Divider()
            Menu("评分 ≥") {
                ForEach([1, 2, 3, 4], id: \.self) { r in
                    Button("★ \(r)+") { setSingle(.rating, .gte, String(r)) }
                }
            }
            Toggle("仅含 PDF", isOn: Binding(
                get: { model.filterClauses.contains { $0.field == .haspdf } },
                set: { on in
                    var next = model.filterClauses.filter { $0.field != .haspdf }
                    if on { next.append(FilterClause(field: .haspdf, op: .yes, value: "")) }
                    model.setFilters(next)
                }
            ))
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func setSingle(_ field: FilterField, _ op: FilterOp, _ value: String) {
        var next = model.filterClauses.filter { $0.field != field }
        next.append(FilterClause(field: field, op: op, value: value))
        model.setFilters(next)
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
