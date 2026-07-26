import SwiftUI
import AppKit

struct NoteMarkdownEditor: NSViewRepresentable {
    let text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    let onDebouncedChange: (String) -> Void
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, height: $height, isFocused: $isFocused,
                    onDebouncedChange: onDebouncedChange, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> PlainTextContainerView {
        let container = PlainTextContainerView()
        let textView = FocusTrackingTextView(frame: .zero)
        textView.onMouseDown = { [weak coordinator = context.coordinator] in coordinator?.focus() }
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 14.5)
        textView.defaultParagraphStyle = Coordinator.paragraphStyle
        textView.typingAttributes = Coordinator.textAttributes
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.delegate = context.coordinator
        context.coordinator.apply(text, to: textView)

        container.textView = textView
        container.onLayout = { [weak coordinator = context.coordinator] in coordinator?.remeasure() }
        context.coordinator.container = container
        context.coordinator.textView = textView
        return container
    }

    func updateNSView(_ container: PlainTextContainerView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.isFocused = $isFocused
        context.coordinator.onDebouncedChange = onDebouncedChange
        context.coordinator.onCommit = onCommit
        guard let textView = container.textView else { return }
        context.coordinator.acceptExternalText(text, in: textView)
        context.coordinator.remeasure()
    }

    final class FocusTrackingTextView: NSTextView {
        var onMouseDown: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onMouseDown?()
            super.mouseDown(with: event)
        }
    }

    final class PlainTextContainerView: NSView {
        var onLayout: (() -> Void)?
        var textView: NSTextView? {
            didSet {
                oldValue?.removeFromSuperview()
                if let textView { addSubview(textView) }
            }
        }

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            guard let textView else { return }
            textView.frame = bounds
            textView.textContainer?.containerSize = NSSize(
                width: max(1, bounds.width),
                height: CGFloat.greatestFiniteMagnitude)
            onLayout?()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var height: Binding<CGFloat>
        var isFocused: Binding<Bool>
        var onDebouncedChange: (String) -> Void
        var onCommit: (String) -> Void
        weak var container: PlainTextContainerView?
        weak var textView: NSTextView?
        var isApplying = false
        private var localDirty = false
        private var lastExternalText: String
        private var saveTask: Task<Void, Never>?

        init(text: String, height: Binding<CGFloat>, isFocused: Binding<Bool>,
             onDebouncedChange: @escaping (String) -> Void,
             onCommit: @escaping (String) -> Void) {
            self.lastExternalText = text
            self.height = height
            self.isFocused = isFocused
            self.onDebouncedChange = onDebouncedChange
            self.onCommit = onCommit
        }

        static let paragraphStyle: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 4
            p.paragraphSpacing = 7
            return p
        }()

        static var textAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: 14.5),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]
        }

        func acceptExternalText(_ text: String, in textView: NSTextView) {
            defer { lastExternalText = text }
            if text == textView.string {
                localDirty = false
                return
            }
            // During IME composition (Chinese/Japanese marked text) textDidChange
            // hasn't fired yet, so localDirty can't protect the buffer — replacing
            // the storage would destroy the composition and throw the caret to the
            // end (issue #87). Never clobber marked text.
            guard !localDirty, !textView.hasMarkedText() else { return }
            isApplying = true
            apply(text, to: textView)
            isApplying = false
        }

        func apply(_ text: String, to textView: NSTextView) {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: text,
                attributes: Self.textAttributes))
            // setAttributedString leaves the caret at the end; keep the user's
            // position (clamped) so an external refresh doesn't yank the cursor.
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(
                location: min(selection.location, length), length: 0))
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            localDirty = true
            scheduleSave(textView.string)
            remeasure()
        }

        func focus() { isFocused.wrappedValue = true }

        func textDidBeginEditing(_ notification: Notification) { focus() }
        func textDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
            saveTask?.cancel(); saveTask = nil
            if let textView {
                localDirty = false
                onCommit(textView.string)
            }
            remeasure()
        }

        private func scheduleSave(_ text: String) {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_700_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.localDirty = false
                    self.onDebouncedChange(text)
                }
            }
        }

        func remeasure() {
            guard let container, let textView, container.bounds.width > 1,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            textContainer.containerSize = NSSize(
                width: max(1, container.bounds.width),
                height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let next = max(80, ceil(used.height + 8))
            guard abs(height.wrappedValue - next) > 1 else { return }
            DispatchQueue.main.async { [height] in
                if abs(height.wrappedValue - next) > 1 { height.wrappedValue = next }
            }
        }
    }
}
