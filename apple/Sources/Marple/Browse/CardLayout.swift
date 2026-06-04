import AppKit
import MarpleKit

/// Single source of truth for the browse card's fonts, spacing, and **measurement**.
/// Both the waterfall layout (which needs each card's height up front) and the cell
/// itself (`CardCellView.layout()`) measure through here, so the reserved height and
/// the rendered content are always identical — no empty gaps, no clipping. Replaces
/// the old `CardMetrics` char-count guess now that AppKit lets us measure for real.
enum CardLayout {
    static var titleFont:   NSFont { .systemFont(ofSize: 15, weight: .semibold) }
    static var metaFont:    NSFont { .systemFont(ofSize: 11, weight: .medium) }
    static var sourceFont:  NSFont { .systemFont(ofSize: 11, weight: .regular) }
    static var previewFont: NSFont { .systemFont(ofSize: 13, weight: .regular) }
    static var themesFont:  NSFont { .systemFont(ofSize: 10.5, weight: .medium) }

    static let gap: CGFloat = 6
    static let titleMaxLines = 2
    static let maxImageHeight: CGFloat = 360
    static let defaultAspect: CGFloat = 1.3

    static func inset(isImage: Bool) -> CGFloat { isImage ? 8 : 16 }

    /// Type → spine colour (the 3pt left bar). Mirrors the demo's palette.
    static func typeColor(_ type: EntryType) -> NSColor {
        switch type {
        case .paper:   return NSColor(srgbRed: 0.23, green: 0.48, blue: 0.82, alpha: 1)  // blue
        case .book:    return NSColor(srgbRed: 0.18, green: 0.62, blue: 0.42, alpha: 1)  // green
        case .author:  return NSColor(srgbRed: 0.54, green: 0.36, blue: 0.82, alpha: 1)  // purple
        case .image:   return NSColor(srgbRed: 0.82, green: 0.54, blue: 0.18, alpha: 1)  // amber
        case .topic:   return NSColor(srgbRed: 0.81, green: 0.31, blue: 0.53, alpha: 1)  // magenta
        case .chapter: return NSColor(srgbRed: 0.20, green: 0.62, blue: 0.62, alpha: 1)  // teal
        case .journal: return NSColor(srgbRed: 0.35, green: 0.42, blue: 0.78, alpha: 1)  // indigo
        case .note, .other: return NSColor.systemGray
        }
    }

    /// Warm accent used (rationed) for the rating star — per the reader spec.
    static var ratingColor: NSColor { NSColor(srgbRed: 0.75, green: 0.22, blue: 0.17, alpha: 1) }

    /// Salience → preview line cap, so cards stagger instead of all hitting one
    /// cap. Rating leads; body thickness nudges. Clamped [2, 11].
    static func previewLines(for entry: Entry) -> Int {
        let base = 2.5 + entry.ratingScore * 1.1 + min(3, Double(entry.preview.count) / 120)
        return max(2, min(11, Int(base.rounded())))
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// Rendered height of `text` wrapped to `width`, capped at `maxLines`.
    static func textHeight(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let lh = lineHeight(font)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let lines = max(1, Int(ceil(bounds.height / lh)))
        return CGFloat(min(lines, maxLines)) * lh
    }

    static func imageHeight(width: CGFloat, aspect: CGFloat?) -> CGFloat {
        min(width / (aspect ?? defaultAspect), maxImageHeight)
    }

    /// Total card height for the waterfall layout, measured the same way the cell
    /// lays out. `columnWidth` is the resolved column width; `aspect` is the image's
    /// real w/h (nil → not yet probed / not an image).
    static func cardHeight(for entry: Entry, columnWidth: CGFloat, aspect: CGFloat?) -> CGFloat {
        let isImage = entry.type == .image
        let pad = inset(isImage: isImage)
        let contentW = columnWidth - pad * 2
        guard contentW > 0 else { return pad * 2 }

        var rows: [CGFloat] = []
        // The meta row always shows (it carries the type label), so reserve it always.
        let title = textHeight(entry.title ?? entry.path, font: titleFont, width: contentW, maxLines: titleMaxLines)

        if isImage {
            rows.append(imageHeight(width: contentW, aspect: aspect))
            rows.append(title)
            rows.append(lineHeight(metaFont))
            if let s = entry.source, !s.isEmpty { rows.append(lineHeight(sourceFont)) }
        } else {
            rows.append(lineHeight(metaFont))
            rows.append(title)
            let p = textHeight(entry.preview, font: previewFont, width: contentW, maxLines: previewLines(for: entry))
            if p > 0 { rows.append(p) }
        }
        if !entry.themes.isEmpty { rows.append(lineHeight(themesFont)) }

        let content = rows.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))
        return content + pad * 2
    }

    static func meta(_ entry: Entry) -> String {
        var parts: [String] = []
        if !entry.author.isEmpty { parts.append(entry.author.joined(separator: ", ")) }
        if let year = entry.year, !year.isEmpty { parts.append(year) }
        return parts.joined(separator: "  ·  ")
    }
}
