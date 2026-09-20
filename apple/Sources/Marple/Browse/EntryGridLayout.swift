import AppKit

/// Flow layout owns row placement and keyboard geometry. Only sizing is custom.
final class EntryGridLayout: NSCollectionViewFlowLayout {
    var preferredItemWidth: CGFloat = 136 {
        didSet {
            if preferredItemWidth != oldValue {
                updateMetrics(width: collectionView?.bounds.width ?? 0)
            }
        }
    }

    override init() {
        super.init()
        itemSize = CardLayout.itemSize(width: preferredItemWidth)
        minimumInteritemSpacing = 12
        minimumLineSpacing = 12
        sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func updateMetrics(width paneWidth: CGFloat) {
        guard paneWidth > 32 else { return }
        let width = min(preferredItemWidth, paneWidth - 32)
        let columns = max(1, floor((paneWidth - 32 + 12) / (width + 12)))
        // Centre the occupied row, keeping gutters stable while thumbnails
        // grow continuously instead of stretching cells to fill the pane.
        let margin = floor((paneWidth - columns * width - (columns - 1) * 12) / 2)
        let size = CardLayout.itemSize(width: width)
        if itemSize != size { itemSize = size }
        if sectionInset.left != margin {
            sectionInset = NSEdgeInsets(top: 16, left: margin, bottom: 16, right: margin)
        }
    }
}
