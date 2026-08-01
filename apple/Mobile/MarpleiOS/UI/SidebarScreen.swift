import SwiftUI
import MarpleKit

struct SidebarScreen: View {
    @Bindable var model: ReaderModel
    @State private var query = ""
    @State private var results: [Entry] = []

    var body: some View {
        Group {
            if query.isEmpty {
                typeList
            } else {
                resultsList
            }
        }
        .navigationTitle("文库")
        .searchable(text: $query, prompt: "搜索全部文档")
        .task(id: query) {
            let q = query
            guard !q.isEmpty else { results = []; return }
            let r = await model.search(q)
            // Guard against a stale async result if the query changed meanwhile.
            if q == query { results = r }
        }
    }

    private var typeList: some View {
        // Count per type once (O(n)), not once-per-row.
        let counts = Dictionary(model.entries.map { ($0.type, 1) }, uniquingKeysWith: +)
        return List {
            if !model.openOnMacSpaces.isEmpty {
                // Ulysses-项目 style: each Space is a navigation row into its own
                // tab list, not an inline disclosure tree.
                Section {
                    ForEach(model.openOnMacSpaces) { space in
                        NavigationLink {
                            MacSpaceScreen(space: space, model: model)
                        } label: {
                            MacSpaceRow(space: space)
                        }
                    }
                } header: {
                    Text("Mac 上打开的")
                } footer: {
                    if let at = model.openTabsUpdatedAt {
                        Text("同步于 \(at, format: .relative(presentation: .named))")
                    }
                }
            }
            Section {
                // Hide types the vault doesn't use — an all-zero row is noise.
                ForEach(EntryType.modeled.filter { (counts[$0] ?? 0) > 0 }, id: \.rawValue) { type in
                    NavigationLink {
                        EntryListScreen(model: model, type: type)
                    } label: {
                        LibraryTypeRow(type: type)
                            .badge(counts[type] ?? 0)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var resultsList: some View {
        List(results) { entry in
            NavigationLink {
                DocScreen(model: model, entry: entry)
            } label: {
                EntrySummaryRow(entry: entry, showsType: true)
            }
        }
        .overlay {
            if results.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

}

private struct MacSpaceRow: View {
    let space: MacSpaceTabs

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: space.iconName ?? "square.grid.2x2")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(space.name)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 5)
    }
}

private struct LibraryTypeRow: View {
    let type: EntryType

    var body: some View {
        Label {
            Text(AppPresentation.entryTypeLabel(type))
                .font(.body)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: type.symbolName)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28)
        }
        .padding(.vertical, 4)
    }
}

/// One Mac Space's tab list, pushed from the sidebar (Ulysses-项目 navigation, not
/// inline expansion). Groups inside still fold, mirroring the Mac's collapsed state.
private struct MacSpaceScreen: View {
    let space: MacSpaceTabs
    @Bindable var model: ReaderModel

    var body: some View {
        List {
            ForEach(space.roots) {
                MacTabNodeView(node: $0, model: model, activePath: space.activePath)
            }
        }
        .navigationTitle(space.name)
    }
}

/// Recursively renders one node of the "Mac 上打开的" forest: a document link or a
/// collapsible group (folder) whose initial expansion mirrors the Mac's collapsed
/// state. The Space's active tab gets a quiet "you are here" mark (medium weight +
/// accent dot), not a filled row.
private struct MacTabNodeView: View {
    let node: MacTabNode
    @Bindable var model: ReaderModel
    let activePath: String?

    var body: some View {
        switch node {
        case .doc(_, let entry, let label):
            let active = entry.path == activePath
            NavigationLink {
                DocScreen(model: model, entry: entry)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: entry.type.symbolName)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(active ? Color.accentColor : .secondary)
                        .frame(width: 22)
                    Text(label).lineLimit(1)
                        .fontWeight(active ? .medium : .regular)
                    if active {
                        Spacer(minLength: 6)
                        Circle().fill(.tint).frame(width: 5, height: 5)
                    }
                }
                .padding(.vertical, 2)
            }
        case .group(_, let name, let collapsed, let children):
            MacTabGroupView(name: name, collapsed: collapsed, children: children,
                            model: model, activePath: activePath)
        }
    }
}

private struct MacTabGroupView: View {
    let name: String
    let children: [MacTabNode]
    @Bindable var model: ReaderModel
    let activePath: String?
    @State private var expanded: Bool

    init(name: String, collapsed: Bool, children: [MacTabNode], model: ReaderModel,
         activePath: String?) {
        self.name = name
        self.children = children
        self.model = model
        self.activePath = activePath
        _expanded = State(initialValue: !collapsed)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(children) {
                MacTabNodeView(node: $0, model: model, activePath: activePath)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(name)
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 2)
        }
    }
}
