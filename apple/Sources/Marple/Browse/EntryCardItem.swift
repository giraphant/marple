import AppKit
import MarpleKit

/// Reusable native item; an explicit loadView also supports the bundle-less SPM app.
final class EntryCardItem: NSCollectionViewItem {
    private var card: CardCellView { view as! CardCellView }
    override var nibName: NSNib.Name? { nil }
    override func loadView() { view = CardCellView() }

    func configure(entry: Entry, nonConforming: Bool, maxPixel: Int,
                   resolveURL: @escaping (String) async -> URL?) {
        card.configure(entry: entry, nonConforming: nonConforming, maxPixel: maxPixel, resolveURL: resolveURL)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.resetForReuse()
    }

    override var isSelected: Bool {
        didSet { card.setSelected(isSelected) }
    }
}

/// A bounded preview followed by two title lines and one metadata line.
private final class CardCellView: NSView {
    private let thumbnail = NSImageView()
    private let placeholder = NSImageView()
    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(wrappingLabelWithString: "")
    private let conformanceDot = NSView()
    private var entryPath: String?
    private var selected = false
    private var loadTask: Task<Void, Never>?
    private let dotSize: CGFloat = 6

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.masksToBounds = true
        placeholder.imageScaling = .scaleNone
        placeholder.contentTintColor = .secondaryLabelColor
        placeholder.symbolConfiguration = .init(pointSize: 24, weight: .regular)
        configureMultiline(titleField, font: CardLayout.titleFont, maxLines: CardLayout.titleMaxLines)
        configureMultiline(previewField, font: CardLayout.previewFont, maxLines: CardLayout.previewMaxLines)
        previewField.textColor = .secondaryLabelColor
        metaField.font = CardLayout.metaFont
        metaField.textColor = .secondaryLabelColor
        metaField.lineBreakMode = .byTruncatingTail
        conformanceDot.wantsLayer = true
        conformanceDot.layer?.cornerRadius = dotSize / 2
        conformanceDot.toolTip = String(localized: "缺少必填字段")
        for view in [thumbnail, placeholder, titleField, metaField, previewField, conformanceDot] {
            addSubview(view)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func configureMultiline(_ field: NSTextField, font: NSFont, maxLines: Int) {
        field.font = font
        field.maximumNumberOfLines = maxLines
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
    }

    func configure(entry: Entry, nonConforming: Bool, maxPixel: Int,
                   resolveURL: @escaping (String) async -> URL?) {
        resetForReuse()
        entryPath = entry.path
        titleField.stringValue = entry.title ?? (entry.path as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
        metaField.stringValue = CardLayout.meta(entry)
        previewField.stringValue = String(entry.preview.prefix(300))
        previewField.isHidden = entry.type == .image || entry.preview.isEmpty
        placeholder.image = NSImage(systemSymbolName: entry.type == .image ? "photo" : "doc.text",
                                    accessibilityDescription: AppPresentation.entryTypeLabel(entry.type))
        placeholder.isHidden = !previewField.isHidden
        conformanceDot.isHidden = !nonConforming
        toolTip = titleField.stringValue + "\n" + metaField.stringValue
        setAccessibilityLabel(toolTip)
        if entry.type == .image {
            let path = entry.path
            loadTask = Task { [weak self] in
                guard let url = await resolveURL(path), !Task.isCancelled else { return }
                let image = await ThumbnailLoader.shared.thumbnail(for: url, maxPixel: maxPixel)
                guard !Task.isCancelled, let self, self.entryPath == path else { return }
                self.thumbnail.image = image
                self.placeholder.isHidden = image != nil
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    func resetForReuse() {
        loadTask?.cancel()
        loadTask = nil
        entryPath = nil
        thumbnail.image = nil
    }

    func setSelected(_ value: Bool) {
        selected = value
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : .clear).cgColor
        layer?.borderColor = (selected ? NSColor.controlAccentColor : .clear).cgColor
        layer?.borderWidth = selected ? 2 : 0
        thumbnail.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        conformanceDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
    }

    override func layout() {
        super.layout()
        let inset = CardLayout.inset
        let width = max(0, bounds.width - inset * 2)
        let previewHeight = CardLayout.previewHeight(width: bounds.width)
        thumbnail.frame = NSRect(x: inset, y: inset, width: width, height: previewHeight)
        placeholder.frame = thumbnail.frame
        previewField.frame = NSRect(x: inset + 8, y: inset + 8, width: max(0, width - 16),
                                   height: CardLayout.lineHeight(CardLayout.previewFont) * CGFloat(CardLayout.previewMaxLines))
        let titleY = thumbnail.frame.maxY + CardLayout.gap
        let dotReserve = conformanceDot.isHidden ? 0 : dotSize + CardLayout.gap
        titleField.frame = NSRect(x: inset, y: titleY, width: max(0, width - dotReserve),
                                 height: CardLayout.lineHeight(CardLayout.titleFont) * CGFloat(CardLayout.titleMaxLines))
        conformanceDot.frame = NSRect(x: bounds.width - inset - dotSize,
            y: titleY + (CardLayout.lineHeight(CardLayout.titleFont) - dotSize) / 2, width: dotSize, height: dotSize)
        metaField.frame = NSRect(x: inset, y: titleField.frame.maxY + CardLayout.gap,
                                width: width, height: CardLayout.lineHeight(CardLayout.metaFont))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}
