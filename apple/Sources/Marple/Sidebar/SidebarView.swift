import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        SidebarOutlineView(model: model)
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
}
