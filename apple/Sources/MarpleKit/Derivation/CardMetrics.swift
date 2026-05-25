import Foundation

/// Estimated rendered card height, used only to balance masonry columns.
/// Approximate by design: the card sizes itself at render time; this drives
/// column assignment, so a rough value is fine. Keyed off `preview` length
/// because native `Entry` has no body length.
public enum CardMetrics {
    public static func estimatedHeight(for entry: Entry, columnWidth: CGFloat = 260) -> CGFloat {
        let verticalPadding: CGFloat = 32          // 16 top + 16 bottom
        let titleLineHeight: CGFloat = 20
        let bodyLineHeight: CGFloat = 17
        let thumbnailHeight: CGFloat = entry.type == .image ? columnWidth * 0.9 : 0

        let titleChars = (entry.title ?? entry.path).count
        let titlePerLine = max(1, Int(columnWidth / 9))
        let titleLines = min(2, max(1, Int(ceil(Double(titleChars) / Double(titlePerLine)))))

        let previewPerLine = max(1, Int(columnWidth / 8))
        let rawPreviewLines = Int(ceil(Double(entry.preview.count) / Double(previewPerLine)))
        let previewLines = min(12, max(0, rawPreviewLines))

        let hasMeta = (entry.author?.isEmpty == false) || (entry.year?.isEmpty == false) || entry.ratingScore > 0
        let metaHeight: CGFloat = hasMeta ? 20 : 0
        let themesHeight: CGFloat = entry.themes.isEmpty ? 0 : 22

        return verticalPadding
            + thumbnailHeight
            + (thumbnailHeight > 0 ? 10 : 0)
            + CGFloat(titleLines) * titleLineHeight
            + metaHeight
            + (previewLines > 0 ? CGFloat(previewLines) * bodyLineHeight + 6 : 0)
            + themesHeight
    }
}
