import AppKit

/// Column-packing waterfall layout for `NSCollectionView`: derive the column
/// count from the available width and the target `columnWidth`, then drop each
/// item into the currently shortest column. Heights come from the injected
/// `heightForItem` (real image ratios via `GridDimensions`, `CardMetrics` for
/// text). Single section. This is the engine Apple's CocoaSlideCollection sample
/// uses (custom layout + native drag/select) — the part that was never the crash.
final class WaterfallCollectionLayout: NSCollectionViewLayout {
    var columnWidth: CGFloat = 260
    var interItemSpacing: CGFloat = 12
    var sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    /// (itemIndex, resolvedColumnWidth) → height.
    var heightForItem: ((Int, CGFloat) -> CGFloat)?

    private var cache: [NSCollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var contentWidth: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        cache.removeAll(keepingCapacity: true)
        contentHeight = 0

        contentWidth = collectionView.bounds.width
        let available = contentWidth - sectionInset.left - sectionInset.right
        // First layout pass can run at zero width; a negative card width makes
        // AppKit throw during view layout. Bail until we have real width.
        guard available > 0 else { return }
        let columns = max(1, Int((available + interItemSpacing) / (columnWidth + interItemSpacing)))
        let totalSpacing = interItemSpacing * CGFloat(columns - 1)
        let colW = max(1, (available - totalSpacing) / CGFloat(columns))

        var columnHeights = Array(repeating: sectionInset.top, count: columns)
        let count = collectionView.numberOfItems(inSection: 0)
        for item in 0..<count {
            let col = columnHeights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            let x = sectionInset.left + CGFloat(col) * (colW + interItemSpacing)
            let y = columnHeights[col]
            let height = max(1, heightForItem?(item, colW) ?? 200)
            let attr = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: item, section: 0))
            attr.frame = NSRect(x: x, y: y, width: colW, height: height)
            cache.append(attr)
            columnHeights[col] = y + height + interItemSpacing
        }
        contentHeight = (columnHeights.max() ?? sectionInset.top) + sectionInset.bottom
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: contentWidth, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        cache.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < cache.count else { return nil }
        return cache[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != contentWidth
    }
}
