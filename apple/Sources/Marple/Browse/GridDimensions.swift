import SwiftUI
import ImageIO
import MarpleKit

/// Aspect-ratio cache for image entries, shared by every grid-engine variant.
///
/// Masonry needs each card's height *before* it renders. Today `CardMetrics`
/// guesses image height as `columnWidth * 0.9` regardless of the real picture —
/// so columns misbalance and cards jump once the bitmap loads. This cache reads
/// the true pixel dimensions from the file header via `CGImageSource` (no full
/// decode), keyed by entry path, and republishes so the layout settles to the
/// correct height. The eventual fix is to derive width/height in the indexer
/// (QUA-114); this demo-time probe proves the layout with real ratios first.
@MainActor
@Observable
final class GridDimensions {
    /// path → aspect ratio (width / height). Absent until probed. Observed, so a
    /// resolved ratio re-triggers the layout.
    private var ratios: [String: CGFloat] = [:]
    @ObservationIgnored private var inflight: Set<String> = []
    /// Memoised card heights — `prepare()` measures every item's height on every
    /// layout pass (resize, density drag, each aspect probe), and the text
    /// measurement (`boundingRect`) is the expensive part. Cache it, validated
    /// against the column width + current aspect so density changes and resolved
    /// ratios invalidate just what they should. Not observed (pure derived cache).
    @ObservationIgnored private var heightCache: [String: (width: CGFloat, aspect: CGFloat?, height: CGFloat)] = [:]
    private let resolveURL: (String) async -> URL?

    init(resolveURL: @escaping (String) async -> URL?) {
        self.resolveURL = resolveURL
    }

    /// Known aspect ratio (w/h) for an image entry, or nil if not yet probed.
    func aspect(for path: String) -> CGFloat? { ratios[path] }

    /// Kick off a one-shot probe for an image entry. No-op for non-images or
    /// already-known/in-flight paths.
    func probe(_ entry: Entry) {
        guard entry.type == .image, ratios[entry.path] == nil,
              !inflight.contains(entry.path) else { return }
        inflight.insert(entry.path)
        let path = entry.path
        Task {
            let url = await resolveURL(path)
            let ratio: CGFloat? = await Task.detached(priority: .utility) {
                url.flatMap(Self.pixelAspect(of:))
            }.value
            inflight.remove(path)
            if let ratio { ratios[path] = ratio }
        }
    }

    /// Rendered card height at a given column width, measured by `CardLayout` so
    /// it exactly matches what the cell lays out (image cards use the real probed
    /// aspect ratio; text is measured by wrapping). Memoised per path.
    ///
    /// `allowStale` (set during live window resize) returns any cached height even
    /// if the width no longer matches, skipping the expensive `boundingRect`
    /// re-measure on every resize frame — the precise height is recomputed once
    /// when live resize ends. Without it, dragging the window re-measures every
    /// card ~60×/sec and stutters badly.
    func estimatedHeight(for entry: Entry, columnWidth: CGFloat, allowStale: Bool = false) -> CGFloat {
        let aspect = aspect(for: entry.path)
        if let c = heightCache[entry.path] {
            if allowStale { return c.height }
            if c.width == columnWidth, c.aspect == aspect { return c.height }
        }
        let h = CardLayout.cardHeight(for: entry, columnWidth: columnWidth, aspect: aspect)
        heightCache[entry.path] = (columnWidth, aspect, h)
        return h
    }

    nonisolated private static func pixelAspect(of url: URL) -> CGFloat? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0 else { return nil }
        return w / h
    }
}
