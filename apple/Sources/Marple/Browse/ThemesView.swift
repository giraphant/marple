import SwiftUI
import MarpleKit

struct ThemesView: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(model.themeIndex) { tc in
                    Button { model.select(pane: .theme(tc.theme)) } label: {
                        HStack {
                            Image(systemName: "tag")
                            Text(tc.theme).lineLimit(1)
                            Spacer()
                            Text("\(tc.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("标签 (\(model.themeIndex.count))")
    }
}
