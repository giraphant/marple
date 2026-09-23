import AppKit
import MarpleKit

extension AppModel {
    /// Body is position zero; unavailable originals are omitted, just as in the
    /// inspector. Stop at either end rather than crossing into another archive.
    @discardableResult func stepArchivePreview(forward: Bool) -> Bool {
        guard let manifest = openArchiveManifest, let path = openPath else { return false }
        let originals = manifest.files.compactMap {
            manifest.localURL(for: $0, entryPath: path, workspaceRoot: workspaceRoot)
        }
        guard !originals.isEmpty else { return false }
        let current = attachmentPreviewURL.flatMap { originals.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let next = current + (forward ? 1 : -1)
        guard next >= 0, next <= originals.count else { return true }
        if next == 0 { attachmentPreviewURL = nil }
        else { previewAttachment(originals[next - 1].absoluteString) }
        return true
    }
}

/// Like FSNotes, route keys by reader focus before embedded preview views consume
/// them. Keep focus across replacement of Markdown/WebKit/Quick Look content.
@MainActor final class ArchiveReaderKeyboard {
    private weak var reader: NSView?
    private let model: AppModel
    private var monitor: Any?
    private var clickedReader = false

    init(model: AppModel, reader: NSView) {
        self.model = model
        self.reader = reader
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func handle(_ event: NSEvent) -> Bool {
        guard let reader, let window = reader.window, event.window === window,
              window.attachedSheet == nil else { return false }
        if event.type == .leftMouseDown {
            let point = reader.convert(event.locationInWindow, from: nil)
            clickedReader = reader.bounds.contains(point)
            if clickedReader, let responder = window.firstResponder as? NSView,
               responder !== reader, !responder.isDescendant(of: reader) {
                window.makeFirstResponder(nil)
            }
            return false
        }
        guard event.type == .keyDown, event.keyCode == 123 || event.keyCode == 124,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        if let responder = window.firstResponder as? NSView {
            guard responder === reader || responder.isDescendant(of: reader) else { return false }
            if let text = responder as? NSTextView, text.isEditable { return false }
            if responder is NSControl { return false }
        } else if !clickedReader { return false }
        guard model.stepArchivePreview(forward: event.keyCode == 124) else { return false }
        // The old embedded view is about to disappear. Subsequent arrow presses
        // still belong to this reader until the user focuses another pane.
        clickedReader = true
        window.makeFirstResponder(nil)
        return true
    }
}
