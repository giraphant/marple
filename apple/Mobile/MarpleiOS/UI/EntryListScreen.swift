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
                EntrySummaryRow(entry: entry)
            }
        }
        .navigationTitle(AppPresentation.entryTypeLabel(type))
        .searchable(text: $query, prompt: Text(String(localized: "在\(AppPresentation.entryTypeLabel(type))中搜索")))
        .overlay {
            if !query.isEmpty && shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: query) {
            guard !query.isEmpty else { hits = []; return }
            hits = (await model.search(query)).filter { $0.type == type }
        }
    }
}
