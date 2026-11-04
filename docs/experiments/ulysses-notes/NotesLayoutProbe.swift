// Compile together with the unchanged NoteMarkdownEditor.swift. Uses synthetic
// text only, creates no windows, and never reads or writes the user's vault.
import AppKit
import SwiftUI
import Observation

final class LayoutCounter: NSObject, NSLayoutManagerDelegate {
    var completions = 0
    var invalidations = 0
    func layoutManagerDidInvalidateLayout(_ sender: NSLayoutManager) {
        invalidations += 1
    }
    func layoutManager(_ layoutManager: NSLayoutManager,
                       didCompleteLayoutFor textContainer: NSTextContainer?,
                       atEnd layoutFinishedFlag: Bool) {
        completions += 1
    }
}

@Observable final class DictionaryState {
    var drafts: [Int: String] = [:]
}
@Observable final class PerNoteState {
    var draft = "text"
}
final class ChangeCounter: @unchecked Sendable {
    // The probe reads and mutates this only synchronously on the main actor.
    var count = 0
}

@MainActor final class EditorFixture {
    var height: CGFloat = 80
    let container: NoteMarkdownEditor.PlainTextContainerView
    let textView: NSTextView
    let coordinator: NoteMarkdownEditor.Coordinator
    let counter = LayoutCounter()
    let storage: NSTextStorage

    init(lines: Int) {
        let text = String(repeating: "This is a synthetic note. 中文笔记用于排版测量。\n", count: lines)
        storage = NSTextStorage()
        let layout = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(textContainer)
        layout.delegate = counter
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80), textContainer: textContainer)
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        container = NoteMarkdownEditor.PlainTextContainerView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        coordinator = NoteMarkdownEditor.Coordinator(text: text, height: .constant(80),
            isFocused: .constant(false), onDebouncedChange: { _ in }, onCommit: { _ in })
        container.textView = textView
        coordinator.container = container
        coordinator.textView = textView
        container.onLayout = { [weak coordinator] in coordinator?.remeasure() }
        coordinator.height = Binding(get: { [weak self] in self?.height ?? 80 },
                                     set: { [weak self] in self?.height = $0 })
        coordinator.apply(text, to: textView)
        // Prime text layout, then use its measured height so unchanged samples
        // don't enqueue spurious height publications due to an unpumped run loop.
        coordinator.remeasure()
        height = max(80, ceil(layout.usedRect(for: textContainer).height + 8))
    }
}

#if !NOTES_ABLATION
@main struct NotesLayoutProbe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var rows: [[String: Any]] = []
        for lines in [20, 500, 2000] {
            let fixture = EditorFixture(lines: lines)
            for scenario in ["unchanged_remeasure", "native_layout_then_remeasure", "width_change_then_remeasure", "append_character_then_remeasure"] {
                var samples: [Double] = []
                fixture.counter.completions = 0
                fixture.counter.invalidations = 0
                for i in 0..<60 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    switch scenario {
                    case "native_layout_then_remeasure":
                        fixture.container.layout()
                    case "width_change_then_remeasure":
                        fixture.container.setFrameSize(NSSize(width: i.isMultiple(of: 2) ? 301 : 300, height: 80))
                    case "append_character_then_remeasure":
                        fixture.storage.append(NSAttributedString(string: "a", attributes: NoteMarkdownEditor.Coordinator.textAttributes))
                    default: break
                    }
                    fixture.coordinator.remeasure()
                    let end = DispatchTime.now().uptimeNanoseconds
                    samples.append(Double(end - start) / 1_000_000)
                    // Drain queued height updates outside the timed section.
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
                }
                samples.sort()
                rows.append(["lines": lines, "scenario": scenario, "iterations": samples.count,
                             "median_ms": samples[samples.count / 2],
                             "p95_ms": samples[Int(Double(samples.count - 1) * 0.95)],
                             "max_ms": samples.last!, "layout_completion_callbacks": fixture.counter.completions,
                             "layout_invalidation_callbacks": fixture.counter.invalidations])
            }
        }
        let state = DictionaryState()
        state.drafts = Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, "text") })
        let changes = ChangeCounter()
        for id in 0..<20 {
            withObservationTracking { _ = state.drafts[id] } onChange: { changes.count += 1 }
        }
        state.drafts[0] = "changed"
        let notes = (0..<20).map { _ in PerNoteState() }
        let perNoteChanges = ChangeCounter()
        for note in notes {
            withObservationTracking { _ = note.draft } onChange: { perNoteChanges.count += 1 }
        }
        notes[0].draft = "changed"
        let output: [String: Any] = [
            "kind": "isolated native editor and Observation mechanism probe; not full-app FPS",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "layout": rows,
            "dictionary_observation": ["observed_keys": 20, "changed_keys": 1,
                                       "invalidated_observers": changes.count],
            "per_note_observation_control": ["observed_notes": 20, "changed_notes": 1,
                                             "invalidated_observers": perNoteChanges.count],
            "limitations": ["No SwiftUI view-tree update counts are measured.",
                            "A layout completion callback is not a full-text relayout counter.",
                            "No display, drawing, file loading, or Ulysses runtime is measured.",
                            "Fixture constructs TextKit 1 manually and calls the real Marple coordinator."]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
    }
}
#endif
