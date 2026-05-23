import SwiftUI
import MarpleKit
import SwiftUILazyContainer

/// Multi-column masonry browse of `visibleEntries`. Lazy per column (only
/// on-screen cards render), so it scales to the full vault. Card heights for
/// column balancing come from CardMetrics (estimated from preview length).
struct EntryGridView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            LazyVMasonry(model.visibleEntries, id: \.path,
                         columns: .adaptive(minSize: 260), spacing: Space.s5) { entry in
                EntryCard(entry: entry)
                    .onTapGesture { Task { await model.open(entry.path) } }
            } contentHeight: { entry in
                .fixed(CardMetrics.estimatedHeight(for: entry))
            }
            .padding(Space.s6)
        }
        .lazyContainer()
    }
}
