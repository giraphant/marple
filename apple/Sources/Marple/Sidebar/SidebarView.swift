import SwiftUI
import MarpleKit

/// One selectable item in the sidebar: a browse category or an open document tab.
private enum SidebarItem: Hashable {
    case pane(Pane)
    case tab(NavTab.ID)
}

/// First-class sidebar (Arc-style), written the standard way: a single native
/// `List` with sections — 物件 / 视图 categories on top, then the open document tabs.
/// Native `List` selection drives both (browse category when browsing, active tab
/// when reading) and native `.onMove` reorders the tabs. A single List (not a VStack
/// wrapping a List) is what renders with correct sidebar insets.
struct SidebarView: View {
    @Bindable var model: AppModel

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.isBrowsing ? .pane(model.pane) : model.activeTabID.map(SidebarItem.tab) },
            set: { item in
                switch item {
                case .pane(let p): model.select(pane: p)
                case .tab(let id): Task { await model.selectTab(id) }
                case nil:          break
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section("物件") {
                ForEach(EntryType.modeled, id: \.self) { t in
                    categoryRow(t.label, icon(for: t), model.counts[t] ?? 0)
                        .tag(SidebarItem.pane(.type(t)))
                }
            }
            Section("视图") {
                categoryRow("主题", "tag", model.themeIndex.count)
                    .tag(SidebarItem.pane(.themesIndex))
                categoryRow("回收站", "trash", model.trashItems.count)
                    .tag(SidebarItem.pane(.trash))
            }
            if !model.tabs.isEmpty {
                Section("标签") {
                    ForEach(model.tabs) { tab in
                        tabRow(tab).tag(SidebarItem.tab(tab.id))
                    }
                    .onMove { from, to in
                        var ids = model.tabs.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        model.setTabOrder(ids)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Marple")
        .safeAreaInset(edge: .bottom) {
            Button { Task { await model.newIdeaNote() } } label: {
                Label("新建笔记", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func categoryRow(_ label: String, _ icon: String, _ count: Int) -> some View {
        Label {
            HStack {
                Text(label)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: { Image(systemName: icon) }
    }

    private func tabRow(_ tab: NavTab) -> some View {
        Label {
            HStack {
                Text(model.tabTitle(tab)).lineLimit(1)
                Spacer(minLength: 0)
                if tab.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: model.tabIsDoc(tab) ? "doc.text" : "list.bullet")
        }
        .contextMenu {
            Button(tab.pinned ? "取消固定" : "固定标签") { model.togglePin(tab.id) }
            Divider()
            Button("关闭标签") { Task { await model.closeTab(tab.id) } }
            Button("关闭其他标签") { Task { await model.closeOtherTabs(tab.id) } }
        }
    }

    private func icon(for t: EntryType) -> String { t.symbolName }
}
