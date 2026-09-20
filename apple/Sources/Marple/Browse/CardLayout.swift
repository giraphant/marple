import AppKit
import MarpleKit

/// Fixed content slots keep mixed image/text entries aligned at every density.
enum CardLayout {
    static var titleFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    static var metaFont: NSFont { .systemFont(ofSize: 11) }
    static var previewFont: NSFont { .systemFont(ofSize: 12) }
    static let inset: CGFloat = 8
    static let gap: CGFloat = 6
    static let titleMaxLines = 2
    static let previewMaxLines = 3

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func previewHeight(width: CGFloat) -> CGFloat { (width - inset * 2) * 0.75 }

    static func itemSize(width: CGFloat) -> NSSize {
        NSSize(width: width, height: ceil(inset * 2 + previewHeight(width: width) + gap * 2
            + lineHeight(titleFont) * CGFloat(titleMaxLines) + lineHeight(metaFont)))
    }

    static func meta(_ entry: Entry) -> String {
        ([AppPresentation.entryTypeLabel(entry.type)] + entry.author.prefix(1)
            + [entry.year ?? ""]).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
