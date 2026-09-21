#if canImport(AppKit)
import AppKit
import ImageIO

/// A bounded thumbnail in the text flow; opening it still previews the original.
/// TextKit asks for bounds again on resize, keeping images inside the text column.
final class ArchiveImageAttachment: NSTextAttachment {
    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
              ] as CFDictionary) else { return nil }
        super.init(data: nil, ofType: nil)
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect,
                                   glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let image, image.size.width > 0 else { return .zero }
        let available = max(1, lineFrag.width - 2 * (textContainer?.lineFragmentPadding ?? 0))
        let width = min(image.size.width, available)
        return NSRect(x: 0, y: 0, width: width, height: image.size.height * width / image.size.width)
    }
}
#endif
