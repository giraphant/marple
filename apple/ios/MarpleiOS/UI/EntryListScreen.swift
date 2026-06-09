import SwiftUI
import MarpleKit

struct EntryListScreen: View {
    @Bindable var model: ReaderModel
    let type: EntryType
    @State private var query = ""
    @State private var hits: [Entry] = []

    private var typeEntries: [Entry] {
        model.entries.filter { $0.type == type }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }
    private var shown: [Entry] { query.isEmpty ? typeEntries : hits }

    var body: some View {
        List(shown) { entry in
            NavigationLink {
                DocScreen(model: model, entry: entry)
            } label: {
                EntryRow(entry: entry)
            }
        }
        .navigationTitle(type.label)
        .searchable(text: $query, prompt: "在\(type.label)中搜索")
        .task(id: query) {
            guard !query.isEmpty else { hits = []; return }
            hits = (await model.search(query)).filter { $0.type == type }
        }
    }
}

private struct EntryRow: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title ?? (entry.path as NSString).lastPathComponent)
                .font(.body).lineLimit(2)
            if !entry.author.isEmpty {
                Text(entry.author.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
