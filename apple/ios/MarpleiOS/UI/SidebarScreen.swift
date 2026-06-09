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
            if !model.openOnMacRoots.isEmpty {
                Section("Mac 上打开的") {
                    ForEach(model.openOnMacRoots) { node in
                        MacTabNodeView(node: node, model: model)
                    }
                }
            }
            Section {
                ForEach(EntryType.modeled, id: \.rawValue) { type in
                    NavigationLink {
                        EntryListScreen(model: model, type: type)
                    } label: {
                        Label(type.label, systemImage: symbol(for: type))
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

/// Sidebar SF Symbol for an entry type. File-level so both the type list and the
/// "Mac 上打开的" forest share one mapping.
func symbol(for type: EntryType) -> String {
    switch type {
    case .paper: "doc.text"; case .book: "book"; case .author: "person"
    case .topic: "tag"; case .journal: "newspaper"; case .chapter: "doc.plaintext"
    case .note: "note.text"; case .image: "photo"; case .talk: "mic"
    default: "doc"
    }
}

/// Recursively renders one node of the "Mac 上打开的" forest: a document link or a
/// collapsible group (folder) whose initial expansion mirrors the Mac's collapsed
/// state.
private struct MacTabNodeView: View {
    let node: MacTabNode
    @Bindable var model: ReaderModel

    var body: some View {
        switch node {
        case .doc(_, let entry, let label):
            NavigationLink {
                DocScreen(model: model, entry: entry)
            } label: {
                Label {
                    Text(label).lineLimit(1)
                } icon: {
                    Image(systemName: symbol(for: entry.type))
                }
            }
        case .group(_, let name, let collapsed, let children):
            MacTabGroupView(name: name, collapsed: collapsed, children: children, model: model)
        }
    }
}

private struct MacTabGroupView: View {
    let name: String
    let children: [MacTabNode]
    @Bindable var model: ReaderModel
    @State private var expanded: Bool

    init(name: String, collapsed: Bool, children: [MacTabNode], model: ReaderModel) {
        self.name = name
        self.children = children
        self.model = model
        _expanded = State(initialValue: !collapsed)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(children) { MacTabNodeView(node: $0, model: model) }
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
