import SwiftUI
import MarpleKit
import SwiftUILazyContainer

/// Multi-column masonry browse of `visibleEntries`. Lazy per column (only
/// on-screen cards render), so it scales to the full vault. Card heights for
/// column balancing come from CardMetrics (estimated from preview length).
struct EntryGridView: View {
    let model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            ScrollView {
                LazyVMasonry(model.visibleEntries, id: \.path,
                             columns: .adaptive(minSize: 260), spacing: Space.s5) { entry in
                    EntryCard(entry: entry) { path in
                        try? await model.client.imageOriginalURL(forImageEntryPath: path)
                    }
                    .onTapGesture { Task { await model.open(entry.path) } }
                } contentHeight: { entry in
                    .fixed(CardMetrics.estimatedHeight(for: entry))
                }
                .padding(Space.s6)
            }

            if acceptsImageDrops && model.visibleEntries.isEmpty {
                ContentUnavailableView(
                    "拖拽图片到这里",
                    systemImage: "photo.on.rectangle",
                    description: Text("会自动创建 vault/images/<名称>/image.md 和 original.<ext>")
                )
                .allowsHitTesting(false)
            }

            if acceptsImageDrops && isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .padding(Space.s6)
                    .allowsHitTesting(false)
            }
        }
        .lazyContainer()
        .dropDestination(for: URL.self, action: handleImageDrop) { targeted in
            isDropTargeted = acceptsImageDrops && targeted
        }
    }

    private var acceptsImageDrops: Bool {
        if case .type(.image) = model.pane { return true }
        return false
    }

    private func handleImageDrop(_ urls: [URL], at _: CGPoint) -> Bool {
        guard acceptsImageDrops else { return false }
        let images = urls.filter(ImageAsset.isSupportedImageURL)
        guard !images.isEmpty else { return false }
        Task {
            for url in images { await model.importImage(from: url) }
        }
        return true
    }
}
