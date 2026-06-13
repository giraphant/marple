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
                            Label(space.name, systemImage: space.iconName ?? "square.grid.2x2")
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
                        Label(type.label, systemImage: type.symbolName)
                            .badge(counts[type] ?? 0)
                    }
                }
            }
        }
    }

    private var resultsList: some View {
        List(results) { entry in
            NavigationLink {
                DocScreen(model: model, entry: entry)
            } label: {
                GlobalResultRow(entry: entry)
            }
        }
        .overlay {
            if results.isEmpty { ContentUnavailableView.search(text: query) }
        }
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
                HStack {
                    Label {
                        Text(label).lineLimit(1)
                            .fontWeight(active ? .medium : .regular)
                    } icon: {
                        Image(systemName: entry.type.symbolName)
                    }
                    if active {
                        Spacer(minLength: 6)
                        Circle().fill(.tint).frame(width: 6, height: 6)
                    }
                }
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
            Label(name, systemImage: "folder")
        }
    }
}

/// A global-search result row: title + a small type chip + author.
private struct GlobalResultRow: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title ?? (entry.path as NSString).lastPathComponent)
                .font(.body).lineLimit(2)
            HStack(spacing: 6) {
                Text(entry.type.label)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                if !entry.author.isEmpty {
                    Text(entry.author.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
