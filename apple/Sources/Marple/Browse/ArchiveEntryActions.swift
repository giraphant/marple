import AppKit
import MarpleKit

extension Entry {
    var isArchiveCollection: Bool { type == .archive && path.hasPrefix("marple-group:") }
}

extension AppModel {
    var archiveBrowseGroups: [ArchiveFieldGroup] {
        guard pane == .type(.archive), !isPinnedListContext, let field = archiveGrouping else { return [] }
        return ArchiveFieldGroup.groups(paths: catalog.visibleEntries.filter { $0.type == .archive }.map(\.path),
                                        fields: archiveFields, by: field)
    }

    var archiveGroupingFields: [String] {
        Set(archiveFields.values.flatMap { $0.filter { !$0.value.isEmpty }.keys })
            .union(["collection"]).union(archiveGrouping.map { [$0] } ?? []).sorted()
    }

    var visibleEntryCount: Int {
        pane == .type(.archive) && !isPinnedListContext ? catalog.visibleEntries.count : visibleEntries.count
    }

    func applyArchiveInventory(_ inventory: ArchiveCollectionInventory) {
        archiveCollections = inventory.collections
        archiveFields = inventory.fields ?? [:]
        archiveCollectionError = inventory.issues.isEmpty ? nil : inventory.issues.joined(separator: "\n")
    }

    func archiveCollection(at path: String) -> ArchiveFieldGroup? {
        archiveBrowseGroups.first { $0.entryPath == path }
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
        pane == .type(.archive) && !isPinnedListContext && archiveGrouping != nil && archiveFields[path] != nil
    }

    func formArchiveCollection(_ paths: [String]) {
        guard !archiveCollectionBusy else { return }
        guard !paths.isEmpty else { return }
        archiveCollectionRenameName = ""
        archiveCollectionAssignPaths = paths
    }

    func renameArchiveCollection(_ group: ArchiveFieldGroup) {
        archiveCollectionRenameName = group.title
        archiveCollectionRenamePath = group.value
    }
}

@MainActor enum ArchiveEntryDrop {
    static func paths(_ board: NSPasteboard, onto target: Entry, model: AppModel) -> [String]? {
        guard !model.archiveCollectionBusy, model.archiveGrouping == "collection", target.type == .archive,
              let items = board.pasteboardItems, !items.isEmpty else { return nil }
        var paths: [String] = []
        for item in items {
            guard let raw = item.string(forType: SidebarDragPasteboard.tabItem), raw.hasPrefix("entry:") else { return nil }
            let path = String(raw.dropFirst(6))
            guard path != target.path, !paths.contains(path),
                  model.entries.contains(where: { $0.path == path && $0.type == .archive && !$0.isArchiveCollection }) else { return nil }
            paths.append(path)
        }
        let members = model.archiveCollection(at: target.path)?.members
            ?? model.archiveCollections.first(where: { $0.members.contains(target.path) })?.members ?? []
        if paths.allSatisfy({ members.contains($0) }) { return nil }
        return paths
    }

    static func accept(_ board: NSPasteboard, onto target: Entry, model: AppModel) -> Bool {
        guard let paths = paths(board, onto: target, model: model) else { return false }
        if let group = model.archiveCollection(at: target.path) {
            model.moveArchives(paths, to: group.value)
        } else if let group = model.archiveCollections.first(where: { $0.members.contains(target.path) }) {
            guard !paths.allSatisfy({ group.members.contains($0) }) else { return false }
            model.moveArchives(paths, to: group.path)
        } else {
            model.formArchiveCollection(paths + [target.path])
        }
        return true
    }
}
