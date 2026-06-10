import SwiftUI
import MarpleKit

/// Card-height memoiser for the waterfall grid.
///
/// Masonry needs each card's height *before* it renders. Image aspect ratios
/// now come straight from the index (`Entry.width`/`height`, derived by
/// `ImageProbe` at build time — QUA-175), so heights are exact on the very
/// first layout pass; the runtime `CGImageSource` probe this class used to run
/// is gone. What remains is the height memo: `prepare()` measures every item's
/// height on every layout pass (resize, density drag), and the text
/// measurement is the expensive part. Cache it, validated against the column
/// width + the entry's aspect so density changes invalidate just what they should.
@MainActor
final class GridDimensions {
    private var heightCache: [String: (width: CGFloat, aspect: CGFloat?, height: CGFloat)] = [:]

    /// Rendered card height at a given column width, measured by `CardLayout` so
    /// it exactly matches what the cell lays out (image cards use the indexed
    /// aspect ratio; text is measured by wrapping). Memoised per path.
    ///
    /// `allowStale` (set during live window resize) returns any cached height even
    /// if the width no longer matches, skipping the re-measure on every resize
    /// frame — the precise height is recomputed once when live resize ends.
    func estimatedHeight(for entry: Entry, columnWidth: CGFloat, allowStale: Bool = false) -> CGFloat {
        let aspect = entry.imageAspect.map { CGFloat($0) }
        if let c = heightCache[entry.path] {
            if allowStale { return c.height }
            if c.width == columnWidth, c.aspect == aspect { return c.height }
        }
        let h = CardLayout.cardHeight(for: entry, columnWidth: columnWidth, aspect: aspect)
        heightCache[entry.path] = (columnWidth, aspect, h)
        return h
    }
}
