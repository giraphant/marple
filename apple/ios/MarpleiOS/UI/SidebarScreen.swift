import SwiftUI
import MarpleKit

struct SidebarScreen: View {
    @Bindable var model: ReaderModel

    var body: some View {
        List(EntryType.modeled, id: \.rawValue) { type in
            NavigationLink {
                EntryListScreen(model: model, type: type)
            } label: {
                Label(type.label, systemImage: symbol(for: type))
                    .badge(model.entries.filter { $0.type == type }.count)
            }
        }
        .navigationTitle("文库")
    }

    private func symbol(for type: EntryType) -> String {
        switch type {
        case .paper: "doc.text"; case .book: "book"; case .author: "person"
        case .topic: "tag"; case .journal: "newspaper"; case .chapter: "doc.plaintext"
        case .note: "note.text"; case .image: "photo"; case .talk: "mic"
        default: "doc"
        }
    }
}
