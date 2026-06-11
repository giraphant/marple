import Foundation
import ImageIO

// MARK: - ImageProbe
//
// Index-time derivation of an image entry's technical fields (pixel width /
// height, file size) from its sibling `original.<ext>` (QUA-175). Replaces the
// old runtime `GridDimensions` CGImageSource probe: deriving once at build time
// means the waterfall grid has exact heights on its very first layout pass and
// never reflows. These values live ONLY in SQLite — they are derived data and
// are never written back into frontmatter (the Quasi spec keeps image
// frontmatter descriptive-only).

public enum ImageProbe {

    public struct Dimensions: Sendable, Equatable {
        /// Display-oriented pixel size: EXIF orientations 5–8 (90°-rotated
        /// camera shots) swap the stored width/height so these match what the
        /// user actually sees. The old runtime probe skipped this, so portrait
        /// phone JPEGs laid out as landscape.
        public let width: Int64
        public let height: Int64
        public let fileSize: Int64
    }

    /// Probe the `original.<ext>` sibling of an image entry's markdown file.
    /// `imageEntryAbsPath` is the absolute path of `…/<slug>/image.md`.
    /// Returns nil when no original exists or its header is unreadable —
    /// the entry still indexes, just without dimensions (grid falls back to
    /// the default aspect).
    public static func probe(imageEntryAbsPath: String) -> Dimensions? {
        let dir = URL(fileURLWithPath: imageEntryAbsPath).deletingLastPathComponent()
        let fm = FileManager.default
        for ext in ImageAsset.supportedExtensions {
            let url = dir.appendingPathComponent("\(ImageAsset.originalStem).\(ext)")
            if fm.fileExists(atPath: url.path) {
                return probeFile(url)
            }
        }
        return nil
    }

    private static func probeFile(_ url: URL) -> Dimensions? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        // EXIF orientation 5–8 = rotated 90°/270°: stored dims are sideways.
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let rotated = (5...8).contains(orientation)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        return Dimensions(
            width: Int64(rotated ? h : w),
            height: Int64(rotated ? w : h),
            fileSize: size ?? 0
        )
    }
}
