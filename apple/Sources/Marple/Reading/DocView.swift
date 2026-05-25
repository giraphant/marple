import SwiftUI
import MarpleKit

struct DocView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.openPath == nil {
                ContentUnavailableView("选择一篇文档", systemImage: "doc.text")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.openBlocks.enumerated()), id: \.offset) { idx, block in
                                BlockView(block: block)
                                    .id(idx)
                                    .padding(.top, topGap(at: idx))
                            }
                        }
                        .padding(.vertical, Space.s9)
                        .frame(maxWidth: Reading.measure, alignment: .leading)
                        .padding(.horizontal, Space.s10)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .onChange(of: model.scrollTarget) { _, target in
                        if let t = target {
                            withAnimation { proxy.scrollTo(t, anchor: .top) }
                            model.scrollTarget = nil
                        }
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        if let target = WikiURL.target(from: url) {
                            Task { await model.follow(target) }
                            return .handled
                        }
                        return .systemAction
                    })
                }
            }
        }
        .overlay(alignment: .top) { toastOverlay }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.toast)
    }

    @ViewBuilder private var toastOverlay: some View {
        if let toast = model.toast {
            ToastBanner(text: toast.text, symbol: toast.symbol)
                .id(toast.id)
                .padding(.top, Space.s7)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(1.6))
                    if model.toast?.id == toast.id { model.toast = nil }
                }
        }
    }

    /// Vertical rhythm between blocks (spec §5): more air *before* a heading than
    /// after it. The first block gets none — the column's own top padding handles it.
    private func topGap(at idx: Int) -> CGFloat {
        let blocks = model.openBlocks
        guard idx > 0 else { return 0 }
        if isHeading(blocks[idx]) { return Space.s8 }      // 24 above a heading
        if isHeading(blocks[idx - 1]) { return Space.s4 }  // 8 just after a heading
        return Space.s6                                     // 16 between body blocks
    }

    private func isHeading(_ block: RenderBlock) -> Bool {
        if case .heading = block { return true }
        return false
    }
}

/// Transient confirmation banner (e.g. 已复制引用), floated near the reader's top.
private struct ToastBanner: View {
    let text: String
    let symbol: String
    @Environment(\.ui) private var ui

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: symbol).foregroundStyle(.green)
            Text(text).font(ui.body)
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }
}
