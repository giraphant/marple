import SwiftUI
import MarpleKit

struct TrashView: View {
    @Bindable var model: AppModel
    @State private var pendingPurge: TrashItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.trashItems.isEmpty {
                // Suppress the "回收站为空" message during bootstrap — the empty
                // array is then ambiguous between "trash is genuinely empty"
                // and "we haven't fetched yet". Show a blank pane instead;
                // loadIndex will populate trashItems within a beat. QUA-105.
                if !model.isBootstrapping {
                    ContentUnavailableView("回收站为空", systemImage: "trash")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(model.trashItems) { item in
                    TrashRow(item: item)
                        .contextMenu {
                            Button("恢复") { Task { await model.restoreTrash(item.name) } }
                            Divider()
                            Button("彻底删除", role: .destructive) { pendingPurge = item }
                        }
                }
            }
        }
        .navigationTitle("回收站")
        .confirmationDialog(
            "彻底删除这个文件？此操作不可撤销。",
            isPresented: Binding(get: { pendingPurge != nil },
                                 set: { if !$0 { pendingPurge = nil } }),
            presenting: pendingPurge
        ) { item in
            Button("彻底删除", role: .destructive) { Task { await model.purgeTrash(item.name) } }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Text("\(model.trashItems.count) 项").foregroundStyle(.secondary)
            Spacer()
            Button { Task { await model.loadTrash() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(String(localized: "刷新"))
        }
        .padding(8)
    }
}

private struct TrashRow: View {
    let item: TrashItem
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.originalBase ?? item.name)
            HStack(spacing: 8) {
                if let ts = item.ts { Text(ts) }
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
