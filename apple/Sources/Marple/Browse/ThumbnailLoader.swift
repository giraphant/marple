import AppKit
import ImageIO

/// Downsampling thumbnail pipeline for the browse grid (QUA-219, after FlowVision).
///
/// The grid used to decode each card's full-size `original.` bitmap (`NSImage(contentsOf:)`)
/// — a 6000×4000 photo became a ~96 MB bitmap just to fill a ~250 pt card, so a large
/// library pinned CPU and memory while scrolling. This loader mirrors FlowVision's three
/// moves:
///
/// 1. **Downsampled decode** — `CGImageSourceCreateThumbnailAtIndex` with
///    `kCGImageSourceThumbnailMaxPixelSize` so only the pixels the card shows are ever
///    decoded (sized by column width × backing scale, not the source resolution).
/// 2. **Bounded LRU** — an `NSCache` keyed by (url, pixel size); cost-limited by decoded
///    bytes so it self-tunes to memory and evicts under pressure (`countLimit` would
///    thrash a grid that shows far more than 16 cards at once).
/// 3. **In-flight de-dup** — one decode per key; a fast scroll that re-requests the same
///    image while it's still decoding waits on the running task instead of decoding twice.
///
/// Visible-priority / off-screen-cancel come for free from the existing cell recycling:
/// only on-screen cells request a load, and `CardCellView` cancels its pending request on
/// reuse — so the cache makes a scroll-back instant while off-screen work is abandoned.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [NSString: Task<NSImage?, Never>] = [:]

    private init() {
        // Cost-limited (decoded bytes), so the cache holds many small thumbnails or a
        // few large ones and shrinks under memory pressure — "按内存调", per the issue.
        cache.totalCostLimit = 256 * 1024 * 1024   // 256 MB of decoded thumbnails
    }

    /// Decode `url` down to `maxPixel` on its longest side, served from / stored in the
    /// LRU and de-duped against any in-flight decode of the same key. Returns nil on an
    /// undecodable file. Safe to call from a cancelled context — the decode still
    /// completes and caches, the caller just discards the result.
    func thumbnail(for url: URL, maxPixel: Int) async -> NSImage? {
        let key = "\(url.absoluteString)@\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<NSImage?, Never> {
            await Task.detached(priority: .utility) {
                Self.downsample(url: url, maxPixel: maxPixel)
            }.value
        }
        inFlight[key] = task
        let image = await task.value
        if let image { cache.setObject(image, forKey: key, cost: cost(of: image)) }
        inFlight[key] = nil
        return image
    }

    private func cost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 1 }
        return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
    }

    private nonisolated static func downsample(url: URL, maxPixel: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: kCFBooleanFalse!] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue!,
            kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue!,   // honour EXIF orientation
            kCGImageSourceShouldCacheImmediately: kCFBooleanTrue!,         // decode now, off the main thread
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Longest-side pixel budget for a card thumbnail: the largest dimension the card can
    /// actually show — the column width, or the 360 pt portrait height cap
    /// (`CardLayout.maxImageHeight`) — times the screen's backing scale, quantised to a
    /// 128 px step so density nudges reuse the same cache bucket instead of thrashing it.
    static func maxPixel(columnWidth: CGFloat, scale: CGFloat) -> Int {
        let points = max(columnWidth, CardLayout.maxImageHeight)
        let step: CGFloat = 128
        let bucket = (points * max(scale, 1) / step).rounded(.up) * step
        return Int(min(max(bucket, 384), 1024))
    }
}
