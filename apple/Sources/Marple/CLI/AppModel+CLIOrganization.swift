import Foundation
import MarpleKit

struct CLIOrganizationError: Error {
    let code: String
    let message: String

    static func invalid(_ message: String) -> Self {
        Self(code: CLIErrorCode.badRequest, message: message)
    }
}

extension AppModel {
    func cliOrganize(_ request: CLIRequest) throws -> CLIResponse {
        let method = request.organizationMethod
        if method == CLIMethod.tabsList { return .success(cliTree()) }
        var edited = workspace ?? Workspace()
        var createdID: UUID?
        let actionName: String
        switch method {
        case CLIMethod.tabsRename:
            let item = try cliItem(request.id, in: edited, kind: "tab")
            guard case .tab(let id) = item else { preconditionFailure() }
            if request.reset == true {
                guard request.title == nil else { throw CLIOrganizationError.invalid("use title or reset, not both") }
                edited.renameTab(id, to: nil)
            } else {
                edited.renameTab(id, to: try cliTitle(request.title))
            }
            actionName = String(localized: "重命名")
        case CLIMethod.foldersRename, CLIMethod.foldersDissolve:
            let item = try cliItem(request.id, in: edited, kind: "folder")
            guard case .group(let id) = item else { preconditionFailure() }
            if method == CLIMethod.foldersRename {
                edited.renameGroup(id, to: try cliTitle(request.title))
                actionName = String(localized: "重命名")
            } else {
                edited.dissolveFolder(id)
                actionName = String(localized: "解散文件夹")
            }
        case CLIMethod.foldersCreate:
            let title = try cliTitle(request.title)
            let items = try cliItems(request.ids ?? [], in: edited)
            let parent = try request.parent.map { try cliFolder($0, in: edited) }
            try cliValidateDestination(items, parent: parent, anchor: nil, in: edited)
            let id = edited.createFolder()
            edited.renameGroup(id, to: title)
            if let parent { edited.moveGroup(id, intoGroup: parent) }
            cliMove(items, parent: id, index: nil, pinned: true, in: &edited)
            createdID = id
            actionName = String(localized: "新建文件夹")
        case CLIMethod.tabsMove, CLIMethod.foldersMove:
            let items = try cliItems(request.ids ?? [], in: edited,
                                     kind: method == CLIMethod.tabsMove ? "tab" : "folder")
            guard !items.isEmpty else { throw CLIOrganizationError.invalid("missing item IDs") }
            let destinations = [request.parent != nil, request.before != nil,
                                request.after != nil, request.root == true].filter { $0 }.count
            guard destinations == 1 else {
                throw CLIOrganizationError.invalid("choose exactly one destination: parent, root, before, or after")
            }
            var parent: UUID?
            var index: Int?
            var pinned = true
            var anchor: WorkspaceItem?
            if let parentID = request.parent {
                parent = try cliFolder(parentID, in: edited)
            } else if let anchorID = request.before ?? request.after {
                let target = try cliItem(anchorID, in: edited)
                anchor = target
                let position = cliPosition(target, nodes: edited.rootNodes)!
                parent = position.parent
                index = position.index + (request.after == nil ? 0 : 1)
                if case .tab(let id) = target {
                    pinned = edited.tabs.first { $0.id == id }!.pinned
                }
            }
            if !pinned, items.contains(where: { if case .group = $0 { true } else { false } }) {
                throw CLIOrganizationError.invalid("folders cannot move into the temporary tabs section")
            }
            try cliValidateDestination(items, parent: parent, anchor: anchor, in: edited)
            cliMove(items, parent: parent, index: index, pinned: pinned, in: &edited)
            actionName = String(localized: "移动页面")
        default:
            throw CLIOrganizationError.invalid("unknown method: \(method)")
        }
        cliApplyWorkspace(edited, actionName: actionName)
        return .success(cliTree(createdID: createdID))
    }

    private func cliTree(createdID: UUID? = nil) -> CLIResponseData {
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        func nodes(_ source: [TabNode]) -> [CLITabNode] {
            source.compactMap { node in
                switch node {
                case .tab(let id):
                    guard let tab = byID[id] else { return nil }
                    return CLITabNode(id: id, kind: "tab", title: tabTitle(tab),
                                      path: tab.identityLocation.openPath, currentPath: tab.location.openPath,
                                      pinned: tab.pinned)
                case .group(let group):
                    return CLITabNode(id: group.id, kind: "folder", title: group.name,
                                      children: nodes(group.children))
                }
            }
        }
        return CLIResponseData(tree: nodes(tabRootNodes), spaceID: activeSpaceID,
                               activeTabID: activeTabID, createdID: createdID)
    }

    private func cliTitle(_ title: String?) throws -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw CLIOrganizationError.invalid("missing or empty title")
        }
        return title
    }

    private func cliItem(_ value: String?, in workspace: Workspace, kind: String? = nil) throws -> WorkspaceItem {
        guard let value, let id = UUID(uuidString: value) else {
            throw CLIOrganizationError.invalid("expected a full tab or folder UUID from tabs list")
        }
        if workspace.tabs.contains(where: { $0.id == id }) {
            guard kind != "folder" else { throw CLIOrganizationError.invalid("expected folder ID: \(value)") }
            return .tab(id)
        }
        if workspace.group(id) != nil {
            guard kind != "tab" else { throw CLIOrganizationError.invalid("expected tab ID: \(value)") }
            return .group(id)
        }
        throw CLIOrganizationError(code: CLIErrorCode.notFound, message: "item not in current Space: \(value)")
    }

    private func cliFolder(_ value: String, in workspace: Workspace) throws -> UUID {
        guard case .group(let id) = try cliItem(value, in: workspace, kind: "folder") else { preconditionFailure() }
        return id
    }

    private func cliItems(_ ids: [String], in workspace: Workspace, kind: String? = nil) throws -> [WorkspaceItem] {
        let resolved = try ids.map { try cliItem($0, in: workspace, kind: kind) }
        let tabs = resolved.compactMap { if case .tab(let id) = $0 { id } else { nil } }
        let groups = resolved.compactMap { if case .group(let id) = $0 { id } else { nil } }
        let filtered = workspace.payloadAncestorFilter(tabIDs: tabs, groupIDs: groups)
        let allowed = Set(filtered.tabs.map(WorkspaceItem.tab) + filtered.groups.map(WorkspaceItem.group))
        var seen: Set<WorkspaceItem> = []
        return resolved.filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    private func cliPosition(_ item: WorkspaceItem, nodes: [TabNode], parent: UUID? = nil) -> (parent: UUID?, index: Int)? {
        for (index, node) in nodes.enumerated() {
            switch node {
            case .tab(let id):
                if item == .tab(id) { return (parent, index) }
            case .group(let group):
                if item == .group(group.id) { return (parent, index) }
                if let found = cliPosition(item, nodes: group.children, parent: group.id) { return found }
            }
        }
        return nil
    }

    private func cliValidateDestination(_ items: [WorkspaceItem], parent: UUID?, anchor: WorkspaceItem?, in workspace: Workspace) throws {
        if let anchor, items.contains(anchor) {
            throw CLIOrganizationError.invalid("destination anchor is also being moved")
        }
        for item in items {
            guard case .group(let id) = item else { continue }
            if let parent, workspace.group(parent, isInsideSubtreeOf: id) {
                throw CLIOrganizationError.invalid("cannot move a folder into itself or its descendants")
            }
        }
    }

    private func cliMove(_ items: [WorkspaceItem], parent: UUID?, index: Int?, pinned: Bool, in workspace: inout Workspace) {
        for item in items {
            if case .tab(let id) = item, let tab = workspace.tabs.first(where: { $0.id == id }), tab.pinned != pinned {
                workspace.togglePin(tab.id)
            }
        }
        if let parent {
            workspace.moveItems(items, toGroup: parent, at: index)
        } else {
            workspace.moveItemsToRoot(items, at: index)
        }
    }
}
