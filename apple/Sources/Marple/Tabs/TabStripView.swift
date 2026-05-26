import SwiftUI
import MarpleKit

/// Horizontal tab strip: back/forward, the tabs (drag to reorder, click to switch,
/// × to close, context-menu to pin), and a + to open a new tab.
///
/// Reorder model ("lift and make room"): the dragged tab follows the cursor exactly
/// (instant offset, never animated → no wobble); only the other tabs animate to open
/// a gap at the computed insertion index. The model order commits on release.
struct TabStripView: View {
    @Bindable var model: AppModel

    private let tabWidth: CGFloat = 150
    private let pinnedWidth: CGFloat = 34
    private let spacing: CGFloat = 4

    @State private var draggingID: NavTab.ID?
    @State private var dragOriginIndex: Int?
    @State private var dragTranslation: CGFloat = 0   // instant, drives the dragged tab
    @State private var gapIndex: Int = 0              // animated, drives the others

    private func slotWidth(_ tab: NavTab) -> CGFloat { tab.pinned ? pinnedWidth : tabWidth }

    private var draggedStep: CGFloat {
        guard let id = draggingID, let t = model.tabs.first(where: { $0.id == id }) else { return tabWidth }
        return slotWidth(t) + spacing
    }

    var body: some View {
        HStack(spacing: 6) {
            navButton("chevron.left", enabled: model.canGoBack) { await model.goBack() }
            navButton("chevron.right", enabled: model.canGoForward) { await model.goForward() }

            Divider().frame(height: 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        chip(tab)
                            .frame(width: slotWidth(tab))
                            .offset(x: xOffset(tab, at: index))
                            .zIndex(tab.id == draggingID ? 1 : 0)
                            .simultaneousGesture(dragGesture(tab, at: index))
                    }
                }
                .padding(.vertical, 1)
            }

            navButton("plus", enabled: true) { await model.newTab() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func xOffset(_ tab: NavTab, at index: Int) -> CGFloat {
        if tab.id == draggingID { return dragTranslation }
        guard draggingID != nil, let origin = dragOriginIndex else { return 0 }
        if origin < gapIndex, index > origin, index <= gapIndex { return -draggedStep }
        if origin > gapIndex, index >= gapIndex, index < origin { return draggedStep }
        return 0
    }

    private func dragGesture(_ tab: NavTab, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if draggingID == nil {
                    draggingID = tab.id
                    dragOriginIndex = index
                    gapIndex = index
                }
                guard draggingID == tab.id, let origin = dragOriginIndex else { return }
                dragTranslation = value.translation.width
                let step = Int((dragTranslation / draggedStep).rounded())
                let newGap = min(max(origin + step, 0), model.tabs.count - 1)
                if newGap != gapIndex {
                    withAnimation(.easeInOut(duration: 0.2)) { gapIndex = newGap }
                }
            }
            .onEnded { _ in
                if let origin = dragOriginIndex, origin != gapIndex {
                    var ids = model.tabs.map(\.id)
                    let moved = ids.remove(at: origin)
                    ids.insert(moved, at: gapIndex)
                    model.setTabOrder(ids)
                }
                withAnimation(.easeOut(duration: 0.18)) {
                    draggingID = nil
                    dragTranslation = 0
                }
                dragOriginIndex = nil
            }
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

    @ViewBuilder
    private func chip(_ tab: NavTab) -> some View {
        let isActive = tab.id == model.activeTabID
        HStack(spacing: 4) {
            Button { Task { await model.selectTab(tab.id) } } label: {
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
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(.separator, lineWidth: tab.id == draggingID ? 1 : 0))
        .help(model.tabTitle(tab))
        .contextMenu {
            Button(tab.pinned ? "取消固定" : "固定页面") { model.togglePin(tab.id) }
            Divider()
            Button("关闭页面") { Task { await model.closeTab(tab.id) } }
                .disabled(model.tabs.count <= 1)
            Button("关闭其他页面") { Task { await model.closeOtherTabs(tab.id) } }
        }
    }
}
