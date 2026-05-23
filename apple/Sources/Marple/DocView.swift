import SwiftUI
import MarpleKit

struct DocView: View {
    @Bindable var model: AppModel
    @State private var inspectorShown = true

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
        .inspector(isPresented: $inspectorShown) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { Task { await model.newIdeaNote() } } label: {
                    Image(systemName: "plus")
                }
                .help("新建笔记")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("新建批注") { Task { await model.newAnnotationForOpenDoc() } }
                    .disabled(model.openEntry == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("用外部编辑器打开") { Task { await model.openExternally() } }
                    .disabled(model.openPath == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { inspectorShown.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
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
