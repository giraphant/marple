// Experimental wrappers around the unchanged production measurement function.
// No windows or user data. These strategies are NOT application changes.
import AppKit

@MainActor final class MeasurementStrategy {
    let fixture: EditorFixture
    let mode: String
    var lastWidth: CGFloat?
    var pending = false
    var calls = 0

    init(_ mode: String, fixture: EditorFixture) {
        self.mode = mode
        self.fixture = fixture
    }
    func request() {
        if mode == "width_guard" {
            // Width-only workload control, NOT a valid cache for text editing.
            guard fixture.container.bounds.width != lastWidth else { return }
        }
        if mode == "coalesced" {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [self] in
                pending = false
                measure()
            }
        } else {
            measure()
        }
    }
    private func measure() {
        calls += 1
        fixture.coordinator.remeasure()
        lastWidth = fixture.container.bounds.width
    }
}

@main struct NotesLayoutAblation {
    @MainActor static func drain() async {
        // First boundary executes queued measurements; second executes any
        // height publications they enqueue. Included in timing for every arm.
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var rows: [[String: Any]] = []
        for run in 0..<3 {
            // Rotate arm order to reduce systematic warm-up/order bias.
            let modes = ["baseline", "width_guard", "coalesced"]
            for offset in 0..<3 {
                let mode = modes[(run + offset) % 3]
                for workload in ["same_width_burst", "four_widths_one_turn", "one_width_per_turn"] {
                    let fixture = EditorFixture(lines: 500)
                    await drain()
                    let strategy = MeasurementStrategy(mode, fixture: fixture)
                    fixture.container.onLayout = { strategy.request() }
                    fixture.counter.completions = 0
                    var samples: [Double] = []
                    var heightsCorrect = true
                    for i in 0..<12 {
                        let start = DispatchTime.now().uptimeNanoseconds
                        for step in 0..<4 {
                            let width: CGFloat = workload == "same_width_burst" ? 300 : CGFloat(300 + (i * 4 + step) % 7)
                            fixture.container.setFrameSize(NSSize(width: width, height: 80))
                            fixture.container.layout()
                            if workload == "one_width_per_turn" { await drain() }
                        }
                        await drain()
                        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                        let expected = max(80, ceil(fixture.textView.layoutManager!.usedRect(for: fixture.textView.textContainer!).height + 8))
                        heightsCorrect = heightsCorrect && abs(fixture.height - expected) <= 1
                    }
                    fixture.container.onLayout = nil
                    samples.sort()
                    rows.append(["run": run, "mode": mode, "workload": workload,
                                 "batches": 12, "width_requests_per_batch": 4,
                                 "median_batch_ms": samples[6], "p95_batch_ms": samples[10],
                                 "measure_calls": strategy.calls,
                                 "layout_completion_callbacks": fixture.counter.completions,
                                 "final_heights_correct": heightsCorrect])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "rows": rows,
            "limits": ["Synthetic width events on one 500-line note; not real mouse events or full-app FPS.",
                       "Width guard is a workload-only ablation, not safe for editing without more invalidation keys.",
                       "Coalescing can remove intermediate measurements only when requests arrive in one turn.",
                       "Native layout and asynchronous height publication are included; no drawing."]
        ], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
