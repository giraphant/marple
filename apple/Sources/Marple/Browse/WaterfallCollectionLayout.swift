import AppKit

/// Column-packing waterfall layout for `NSCollectionView`: derive the column
/// count from the available width and the target `columnWidth`, then drop each
/// item into the currently shortest column. Heights come from the injected
/// `heightForItem` (indexed image dimensions + measured text, memoised by
/// `GridDimensions`). Single section. This is the engine Apple's CocoaSlideCollection sample
/// uses (custom layout + native drag/select) — the part that was never the crash.
final class WaterfallCollectionLayout: NSCollectionViewLayout {
    var columnWidth: CGFloat = 260
    var interItemSpacing: CGFloat = 12
    var sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    /// (itemIndex, resolvedColumnWidth) → height.
    var heightForItem: ((Int, CGFloat) -> CGFloat)?

    private var cache: [NSCollectionViewLayoutAttributes] = []
    /// `cache` sorted by frame.minY, for a binary-searched visible window so
    /// `layoutAttributesForElements(in:)` isn't an O(n) scan of every item on
    /// every scroll/redraw (that was the large-list stutter).
    private var sortedByMinY: [NSCollectionViewLayoutAttributes] = []
    private var maxItemHeight: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var contentWidth: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        cache.removeAll(keepingCapacity: true)
        sortedByMinY.removeAll(keepingCapacity: true)
        maxItemHeight = 0
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
            maxItemHeight = max(maxItemHeight, height)
            columnHeights[col] = y + height + interItemSpacing
        }
        contentHeight = (columnHeights.max() ?? sectionInset.top) + sectionInset.bottom
        sortedByMinY = cache.sorted { $0.frame.minY < $1.frame.minY }
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: contentWidth, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard !sortedByMinY.isEmpty else { return [] }
        // Any item that intersects `rect` has minY in [rect.minY - maxItemHeight, rect.maxY].
        // Binary-search that band and scan only it, instead of all N items.
        let lowerY = rect.minY - maxItemHeight
        var lo = 0, hi = sortedByMinY.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedByMinY[mid].frame.minY < lowerY { lo = mid + 1 } else { hi = mid }
        }
        var result: [NSCollectionViewLayoutAttributes] = []
        var i = lo
        while i < sortedByMinY.count, sortedByMinY[i].frame.minY <= rect.maxY {
            if sortedByMinY[i].frame.intersects(rect) { result.append(sortedByMinY[i]) }
            i += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < cache.count else { return nil }
        return cache[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != contentWidth
    }
}
