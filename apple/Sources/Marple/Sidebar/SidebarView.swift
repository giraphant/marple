import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        SidebarOutlineView(model: model)
            .navigationTitle("Marple")
    }
}
