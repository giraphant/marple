import SwiftUI
import AppKit
import MarpleKit

/// One shared folder strip above all three Archive browsing presentations.
struct ArchiveCollectionsView: View {
    @Bindable var model: AppModel
    @State private var editing = false
    @State private var renamePath: String?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    model.archiveCollectionPath = nil
                } label: { Label("档案", systemImage: "archivebox") }
                .onDrop(of: [SidebarDragPasteboard.tabItem.rawValue], delegate: ArchiveCollectionDrop(model: model, destination: ArchiveCollections.base))
                if let group = model.archiveCollections.first(where: { $0.path == model.archiveCollectionPath }) {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    Text(group.title).lineLimit(1)
                }
                Spacer()
                Button {
                    renamePath = nil; name = ""; editing = true
                } label: { Image(systemName: "folder.badge.plus") }
                .help("新建合集")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.archiveCollections) { group in
                        Button { model.archiveCollectionPath = group.path } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(group.title, systemImage: "folder").lineLimit(1)
                                Text("\(group.members.count) 个档案").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(minWidth: 90, maxWidth: 190, alignment: .leading)
                            .background(model.archiveCollectionPath == group.path ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(group.path)
                        .onDrop(of: [SidebarDragPasteboard.tabItem.rawValue], delegate: ArchiveCollectionDrop(model: model, destination: group.path))
                        .contextMenu {
                            Button("重命名") {
                                renamePath = group.path; name = group.title; editing = true
                            }
                            Button("编辑合集说明") {
                                Task {
                                    do { try await model.client.openInEditor(path: group.path + "/collection.md", app: "") }
                                    catch { model.archiveCollectionError = String(describing: error) }
                                }
                            }
                        }
                    }
                }
            }
            if let error = model.archiveCollectionError {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button { model.archiveCollectionError = nil } label: { Image(systemName: "xmark") }
                }
            }
        }
        .padding(8)
        .buttonStyle(.borderless)
        .disabled(model.archiveCollectionBusy)
        .task { await model.reloadArchiveCollections() }
        .alert(renamePath == nil ? "新建合集" : "重命名合集", isPresented: $editing) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let command = ArchiveCollectionCommand(action: renamePath == nil ? "create" : "rename",
                    paths: renamePath.map { [$0] } ?? [], name: name)
                Task {
                    do { _ = try await model.performArchiveCollection(command) }
                    catch { model.archiveCollectionError = String(describing: error) }
                }
            }
        }
    }
}

private struct ArchiveCollectionDrop: DropDelegate {
    let model: AppModel
    let destination: String
    func validateDrop(info: DropInfo) -> Bool { !model.archiveCollectionBusy && info.hasItemsConforming(to: [SidebarDragPasteboard.tabItem.rawValue]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard !model.archiveCollectionBusy else { return false }
        let providers = info.itemProviders(for: [SidebarDragPasteboard.tabItem.rawValue])
        Task { @MainActor in
            var paths: [String] = []
            for provider in providers {
                let value: String? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: SidebarDragPasteboard.tabItem.rawValue) { data, _ in
                        continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                    }
                }
                guard let value, value.hasPrefix("entry:") else { return }
                paths.append(String(value.dropFirst(6)))
            }
            if !paths.isEmpty { model.moveArchives(paths, to: destination) }
        }
        return true
    }
}
