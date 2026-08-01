import SwiftUI
import MarpleKit

/// Multi-column masonry browse of `visibleEntries` (QUA-114), backed by a native
/// `NSCollectionView` + custom waterfall layout + pure-AppKit cells
/// (`CollectionGridVariant`). Native scrolling, single-click select, ⌘/⇧
/// multi-select, rubber-band marquee, item drag, double-click to open. Image card
/// heights come from indexed pixel dimensions (`Entry.width`/`height`, QUA-175).
/// A density slider sets the target column width.
struct EntryGridView: View {
    let model: AppModel
    @State private var columnWidth: CGFloat = 260
    @State private var dims = GridDimensions()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                CollectionGridVariant(model: model, dims: dims, columnWidth: columnWidth)

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
            .dropDestination(for: URL.self, action: handleImageDrop) { targeted in
                isDropTargeted = acceptsImageDrops && targeted
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.s5) {
            Button { model.browseMode = .list } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help(String(localized: "切换到列表"))

            Spacer(minLength: Space.s4)

            HStack(spacing: Space.s2) {
                Image(systemName: "rectangle.grid.3x2").foregroundStyle(.secondary)
                Slider(value: $columnWidth, in: 180...380)
                    .frame(width: 120)
                Image(systemName: "rectangle.grid.1x2").foregroundStyle(.secondary)
            }

            Text("\(model.visibleEntries.count)")
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
    }

    /// During bootstrap (data still loading) the drop-zone must not appear:
    /// `visibleEntries.isEmpty` is true regardless of whether the vault is
    /// genuinely empty. QUA-105.
    private var acceptsImageDrops: Bool {
        guard !model.isBootstrapping else { return false }
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
