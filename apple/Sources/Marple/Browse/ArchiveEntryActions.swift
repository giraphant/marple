import AppKit
import MarpleKit

extension Entry {
    var isArchiveCollection: Bool { type == .archive && path.hasSuffix("/collection.md") }
}

extension AppModel {
    func archiveCollection(at path: String) -> ArchiveCollection? {
        archiveCollections.first { $0.path + "/collection.md" == path }
    }

    @discardableResult func openArchiveCollection(_ path: String) -> Bool {
        guard let group = archiveCollection(at: path) else { return false }
        if pane != .type(.archive) { select(pane: .type(.archive)) }
        expandedArchiveCollections.insert(group.path)
        return true
    }

    func toggleArchiveCollection(_ path: String) {
        guard let group = archiveCollection(at: path) else { return }
        if !expandedArchiveCollections.insert(group.path).inserted {
            expandedArchiveCollections.remove(group.path)
        }
    }

    func archiveMemberIndent(_ path: String) -> Bool {
        pane == .type(.archive) && !isPinnedListContext && archiveCollections.contains { $0.members.contains(path) }
    }

    func formArchiveCollection(_ paths: [String]) {
        guard !archiveCollectionBusy else { return }
        Task {
            do {
                let base = String(localized: "新合集")
                let root = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(ArchiveCollections.base)
                var name = base, suffix = 2
                while FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
                    name = "\(base) \(suffix)"; suffix += 1
                }
                _ = try await performArchiveCollection(.init(action: "create", paths: paths, name: name))
            } catch { archiveCollectionError = String(describing: error) }
        }
    }

    func renameArchiveCollection(_ group: ArchiveCollection) {
        archiveCollectionRenameName = group.title
        archiveCollectionRenamePath = group.path
    }
}

@MainActor enum ArchiveEntryDrop {
    static func paths(_ board: NSPasteboard, onto target: Entry, model: AppModel) -> [String]? {
        guard !model.archiveCollectionBusy, target.type == .archive,
              let items = board.pasteboardItems, !items.isEmpty else { return nil }
        var paths: [String] = []
        for item in items {
            guard let raw = item.string(forType: SidebarDragPasteboard.tabItem), raw.hasPrefix("entry:") else { return nil }
            let path = String(raw.dropFirst(6))
            guard path != target.path, !paths.contains(path),
                  model.entries.contains(where: { $0.path == path && $0.type == .archive && !$0.isArchiveCollection }) else { return nil }
            paths.append(path)
        }
        if let group = model.archiveCollection(at: target.path) ?? model.archiveCollections.first(where: { $0.members.contains(target.path) }), paths.allSatisfy({ group.members.contains($0) }) { return nil }
        return paths
    }

    static func accept(_ board: NSPasteboard, onto target: Entry, model: AppModel) -> Bool {
        guard let paths = paths(board, onto: target, model: model) else { return false }
        if let group = model.archiveCollection(at: target.path) {
            model.moveArchives(paths, to: group.path)
        } else if let group = model.archiveCollections.first(where: { $0.members.contains(target.path) }) {
            guard !paths.allSatisfy({ group.members.contains($0) }) else { return false }
            model.moveArchives(paths, to: group.path)
        } else {
            model.formArchiveCollection(paths + [target.path])
        }
        return true
    }
}
