import SwiftUI
import MarpleKit

/// Horizontal tab strip: back/forward, the tabs (drag to reorder, click to switch,
/// × to close, context-menu to pin), and a + to open a new tab.
struct TabStripView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            navButton("chevron.left", enabled: model.canGoBack) { await model.goBack() }
            navButton("chevron.right", enabled: model.canGoForward) { await model.goForward() }

            Divider().frame(height: 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        TabChip(model: model, tab: tab, isActive: tab.id == model.activeTabID)
                    }
                }
            }

            navButton("plus", enabled: true) { await model.newTab() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func navButton(_ symbol: String, enabled: Bool,
                           _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
    }
}

private struct TabChip: View {
    @Bindable var model: AppModel
    let tab: NavTab
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button {
                Task { await model.selectTab(tab.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.tabIsDoc(tab) ? "doc.text" : "list.bullet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !tab.pinned {
                        Text(model.tabTitle(tab)).font(.callout).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if tab.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Button { Task { await model.closeTab(tab.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.tabs.count <= 1)
                .opacity(model.tabs.count <= 1 ? 0.3 : 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: tab.pinned ? nil : 180)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .help(model.tabTitle(tab))
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let from = UUID(uuidString: s) else { return false }
            model.moveTab(id: from, before: tab.id)
            return true
        }
        .contextMenu {
            Button(tab.pinned ? "取消固定" : "固定标签") { model.togglePin(tab.id) }
            Divider()
            Button("关闭标签") { Task { await model.closeTab(tab.id) } }
                .disabled(model.tabs.count <= 1)
            Button("关闭其他标签") { Task { await model.closeOtherTabs(tab.id) } }
        }
    }
}
