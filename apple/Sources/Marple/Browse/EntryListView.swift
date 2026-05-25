import SwiftUI
import MarpleKit

struct EntryListView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(model.visibleEntries, selection: Binding(
            get: { model.openPath },
            set: { if let p = $0 { Task { await model.open(p) } } }
        )) { entry in
            EntryRow(entry: entry)
                .contextMenu {
                    Button("在新标签页打开") { Task { await model.openInNewTab(entry.path) } }
                    Button("新建批注") { Task { await model.newAnnotation(for: entry) } }
                    Divider()
                    Button("移到回收站", role: .destructive) {
                        Task { await model.moveToTrash(entry.path) }
                    }
                }
        }
        .listStyle(.inset)
    }
}

/// Shared browse header for both list and card modes (so the view toggle stays
/// reachable in either): the pane name + count on the left; icon-only search /
/// sort / filter / view-mode controls on the right. The pane name lives here,
/// not in the window title bar.
struct BrowseHeader: View {
    @Bindable var model: AppModel
    @State private var showSearch = false
    @Environment(\.ui) private var ui

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(paneTitle).font(ui.title).foregroundStyle(.primary)
                    Text("\(model.visibleEntries.count)")
                        .font(ui.body).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button {
                    showSearch.toggle()
                    if !showSearch { model.setSearchText("") }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showSearch ? Color.accentColor : Color.secondary)
                .help("在当前列表内搜索")
                sortMenu
                filterMenu
                viewToggle
            }
            if showSearch {
                SearchField(model: model)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var paneTitle: String {
        switch model.pane {
        case .type(let t):   return t.label
        case .theme(let n):  return n
        case .themesIndex:   return "主题"
        case .trash:         return "回收站"
        }
    }

    private var viewToggle: some View {
        Button {
            model.browseMode = (model.browseMode == .list) ? .grid : .list
        } label: {
            Image(systemName: model.browseMode == .list ? "square.grid.2x2" : "rectangle.grid.1x2")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(model.browseMode == .list ? "切换到卡片" : "切换到列表")
    }

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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.sortClauses.isEmpty ? Color.secondary : Color.accentColor)
        .help("排序")
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
            Image(systemName: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.filterClauses.isEmpty ? Color.secondary : Color.accentColor)
        .help("筛选")
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
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("检索 标题/作者/主题…", text: Binding(
                get: { model.searchText },
                set: { model.setSearchText($0) }
            ))
            .textFieldStyle(.plain)
            .focused($focused)
            if !model.searchText.isEmpty {
                Button { model.setSearchText("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { focused = true }
    }
}
