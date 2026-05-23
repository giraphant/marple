import SwiftUI
import MarpleKit

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding<Pane?>(
            get: { model.pane },
            set: { if let p = $0 { model.select(pane: p) } }
        )) {
            Section("物件") {
                ForEach(EntryType.modeled, id: \.self) { t in
                    Label {
                        HStack {
                            Text(t.label)
                            Spacer()
                            Text("\(model.counts[t] ?? 0)")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: { Image(systemName: icon(for: t)) }
                    .tag(Pane.type(t))
                }
            }
            Section("视图") {
                Label {
                    HStack {
                        Text("主题")
                        Spacer()
                        Text("\(model.themeIndex.count)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: { Image(systemName: "tag") }
                .tag(Pane.themesIndex)

                Label {
                    HStack {
                        Text("回收站")
                        Spacer()
                        Text("\(model.trashItems.count)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: { Image(systemName: "trash") }
                .tag(Pane.trash)
            }
        }
        .navigationTitle("Marple")
        .safeAreaInset(edge: .bottom) {
            Button { Task { await model.newIdeaNote() } } label: {
                Label("新建笔记", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func icon(for t: EntryType) -> String {
        switch t {
        case .paperAnalysis:  return "doc.text"
        case .bookOverview:   return "book"
        case .authorProfile:  return "person"
        case .topicSynthesis: return "square.stack.3d.up"
        case .chapterSummary: return "list.bullet.rectangle"
        case .note:           return "note.text"
        case .other:          return "questionmark.square.dashed"
        }
    }
}
