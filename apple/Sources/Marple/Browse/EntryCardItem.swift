import AppKit
import MarpleKit

/// Pure-AppKit browse card for the NSCollectionView grid — mirrors the SwiftUI
/// `EntryCard` (rounded surface + hairline; meta / title / preview / themes; image
/// entries lead with the local original) using `NSImageView` + `NSTextField`.
///
/// **No Auto Layout.** Every subview is positioned by hand in `CardCellView.layout()`
/// using `CardLayout` measurement — the exact same numbers the waterfall layout used
/// to reserve the card's height, so content fills the card with no gap or clip. (The
/// boot crashes during QUA-114 were the bundle-less-SPM nib trap, not layout.)
final class EntryCardItem: NSCollectionViewItem {
    private var card: CardCellView { view as! CardCellView }

    /// This SPM executable has no main bundle, so NSViewController's default nib
    /// auto-load (by class name) throws. Force the code-based `loadView()`.
    override var nibName: NSNib.Name? { nil }

    override func loadView() { view = CardCellView() }

    func configure(entry: Entry, nonConforming: Bool, maxPixel: Int,
                   resolveURL: @escaping (String) async -> URL?) {
        card.configure(entry: entry, nonConforming: nonConforming, maxPixel: maxPixel,
                       resolveURL: resolveURL)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.resetForReuse()
    }

    override var isSelected: Bool {
        didSet { card.setSelected(isSelected) }
    }
}

/// The card surface. Flipped (top-down y), manually laid out, layer-drawn chrome.
/// Returns itself from hitTest so clicks reach the collection view for native
/// selection / marquee / drag rather than being swallowed by the labels.
private final class CardCellView: NSView {
    private let thumbnail = NSImageView()
    private let placeholder = NSImageView()
    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let ratingField = NSTextField(labelWithString: "")
    private let sourceField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(wrappingLabelWithString: "")
    private let themesField = NSTextField(labelWithString: "")
    private let conformanceDot = NSView()
    /// 3pt colour bar on the left edge encoding the entry type.
    private let spineLayer = CALayer()

    private var entry: Entry?
    private var nonConforming = false
    private var selected = false
    private var loadTask: Task<Void, Never>?

    private let dotSize: CGFloat = 6
    private let spineWidth: CGFloat = 3

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    private var isImage: Bool { entry?.type == .image }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = true   // clip the spine to the rounded corners

        // Disable implicit animation so the spine doesn't lag/trail during resize.
        spineLayer.actions = ["frame": NSNull(), "position": NSNull(),
                              "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(spineLayer)

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 8
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        placeholder.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        placeholder.imageScaling = .scaleNone
        placeholder.contentTintColor = .secondaryLabelColor
        placeholder.symbolConfiguration = .init(pointSize: 28, weight: .regular)

        configureMultiline(titleField, font: CardLayout.titleFont, maxLines: CardLayout.titleMaxLines)
        configureMultiline(previewField, font: CardLayout.previewFont, maxLines: 8)  // per-entry in configure
        previewField.textColor = .secondaryLabelColor

        configureSingleLine(metaField, font: CardLayout.metaFont, color: .secondaryLabelColor)
        configureSingleLine(ratingField, font: CardLayout.metaFont, color: CardLayout.ratingColor)
        ratingField.alignment = .right
        configureSingleLine(sourceField, font: CardLayout.sourceFont, color: .secondaryLabelColor)
        configureSingleLine(themesField, font: CardLayout.themesFont, color: .tertiaryLabelColor)

        conformanceDot.wantsLayer = true
        conformanceDot.layer?.cornerRadius = dotSize / 2
        conformanceDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        conformanceDot.toolTip = "缺少必填字段"

        for v in [thumbnail, placeholder, titleField, metaField, ratingField,
                  sourceField, previewField, themesField, conformanceDot] {
            addSubview(v)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func configureMultiline(_ f: NSTextField, font: NSFont, maxLines: Int) {
        f.font = font
        f.maximumNumberOfLines = maxLines
        f.lineBreakMode = .byTruncatingTail
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
    }

    private func configureSingleLine(_ f: NSTextField, font: NSFont, color: NSColor) {
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.usesSingleLineMode = true
        f.cell?.wraps = false
    }

    func configure(entry: Entry, nonConforming: Bool, maxPixel: Int,
                   resolveURL: @escaping (String) async -> URL?) {
        self.entry = entry
        self.nonConforming = nonConforming

        titleField.stringValue = entry.title ?? (entry.path as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
        metaField.attributedStringValue = metaAttributed(entry)
        ratingField.stringValue = entry.ratingScore > 0 ? "★ \(Int(entry.ratingScore.rounded()))" : ""
        sourceField.stringValue = entry.source ?? ""
        previewField.stringValue = entry.preview
        previewField.maximumNumberOfLines = CardLayout.previewLines(for: entry)
        themesField.stringValue = entry.themes.prefix(4).joined(separator: " · ")
        spineLayer.backgroundColor = CardLayout.typeColor(entry.type).cgColor

        thumbnail.isHidden = !isImage
        placeholder.isHidden = true
        metaField.isHidden = false   // always shows (carries the type label)
        ratingField.isHidden = ratingField.stringValue.isEmpty
        sourceField.isHidden = !isImage || sourceField.stringValue.isEmpty
        previewField.isHidden = isImage || previewField.stringValue.isEmpty
        themesField.isHidden = themesField.stringValue.isEmpty
        conformanceDot.isHidden = !nonConforming

        loadTask?.cancel()
        thumbnail.image = nil
        if isImage {
            placeholder.isHidden = false
            let p = entry.path
            loadTask = Task { [weak self] in
                guard let url = await resolveURL(p) else { return }
                let image = await ThumbnailLoader.shared.thumbnail(for: url, maxPixel: maxPixel)
                guard !Task.isCancelled, let self, self.entry?.path == p else { return }
                self.thumbnail.image = image
                self.placeholder.isHidden = (image != nil)
            }
        }
        needsLayout = true
    }

    func resetForReuse() {
        loadTask?.cancel()
        loadTask = nil
        thumbnail.image = nil
    }

    func setSelected(_ value: Bool) {
        selected = value
        needsDisplay = true
    }

    /// Meta line: the type label (in its colour) leads, then author · year in
    /// secondary. So the type reads even where the spine colour can't carry it.
    private func metaAttributed(_ entry: Entry) -> NSAttributedString {
        let s = NSMutableAttributedString(string: entry.type.label, attributes: [
            .foregroundColor: CardLayout.typeColor(entry.type), .font: CardLayout.metaFont])
        let rest = CardLayout.meta(entry)
        if !rest.isEmpty {
            s.append(NSAttributedString(string: "  ·  ", attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor, .font: CardLayout.metaFont]))
            s.append(NSAttributedString(string: rest, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: CardLayout.metaFont]))
        }
        return s
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = selected ? 2 : 1
    }

    override func layout() {
        super.layout()
        guard let entry else { return }
        spineLayer.frame = CGRect(x: 0, y: 0, width: spineWidth, height: bounds.height)
        let pad = CardLayout.inset(isImage: isImage)
        let contentW = bounds.width - pad * 2
        guard contentW > 0 else { return }
        let gap = CardLayout.gap

        // Ordered rows, each with its measured height (same math as CardLayout.cardHeight).
        enum Row { case thumb(CGFloat), meta(CGFloat), title(CGFloat), single(NSTextField, CGFloat) }
        var rows: [Row] = []

        let titleH = CardLayout.textHeight(titleField.stringValue, font: CardLayout.titleFont,
                                           width: contentW, maxLines: CardLayout.titleMaxLines)
        let hasMeta = !metaField.isHidden || !ratingField.isHidden
        let metaH = CardLayout.lineHeight(CardLayout.metaFont)

        if isImage {
            rows.append(.thumb(0))   // height filled below from remainder
            rows.append(.title(titleH))
            if hasMeta { rows.append(.meta(metaH)) }
            if !sourceField.isHidden {
                rows.append(.single(sourceField, CardLayout.lineHeight(CardLayout.sourceFont)))
            }
        } else {
            if hasMeta { rows.append(.meta(metaH)) }
            rows.append(.title(titleH))
            if !previewField.isHidden {
                rows.append(.single(previewField,
                    CardLayout.textHeight(previewField.stringValue, font: CardLayout.previewFont,
                                          width: contentW, maxLines: CardLayout.previewLines(for: entry))))
            }
        }
        if !themesField.isHidden {
            rows.append(.single(themesField, CardLayout.lineHeight(CardLayout.themesFont)))
        }

        // Picture takes the remainder so the card fills exactly to its reserved height.
        let nonThumb = rows.filter { if case .thumb = $0 { return false } else { return true } }
        let nonThumbH = nonThumb.reduce(CGFloat(0)) { acc, r in
            switch r {
            case .meta(let h), .title(let h), .single(_, let h): return acc + h
            case .thumb: return acc
            }
        } + gap * CGFloat(max(0, nonThumb.count - 1))
        let thumbH = isImage ? max(0, bounds.height - pad * 2 - nonThumbH - (nonThumb.isEmpty ? 0 : gap)) : 0

        var y = pad
        for (i, row) in rows.enumerated() {
            if i > 0 { y += gap }
            switch row {
            case .thumb:
                thumbnail.frame = NSRect(x: pad, y: y, width: contentW, height: thumbH)
                placeholder.frame = thumbnail.frame
                y += thumbH
            case .meta(let h):
                let ratingW = ratingField.isHidden ? 0 : ceil(ratingField.fittingSize.width)
                metaField.frame = NSRect(x: pad, y: y,
                                         width: contentW - (ratingW > 0 ? ratingW + gap : 0), height: h)
                ratingField.frame = NSRect(x: bounds.width - pad - ratingW, y: y, width: ratingW, height: h)
                y += h
            case .title(let h):
                let dotReserve = nonConforming ? dotSize + gap : 0
                titleField.frame = NSRect(x: pad, y: y, width: contentW - dotReserve, height: h)
                if nonConforming {
                    conformanceDot.frame = NSRect(x: bounds.width - pad - dotSize,
                                                  y: y + (CardLayout.lineHeight(CardLayout.titleFont) - dotSize) / 2,
                                                  width: dotSize, height: dotSize)
                }
                y += h
            case .single(let f, let h):
                f.frame = NSRect(x: pad, y: y, width: contentW, height: h)
                y += h
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}
