import Foundation
import Darwin

/// Persistent log + opt-in in-process memory watchdog (QUA-OOM diagnostics).
///
/// A Finder-launched .app sends `print()` to /dev/null, so the existing
/// diagnostics (`loadEntries: cache MISS …`, `watcher reload …`) vanish — which
/// is why a one-off 48 GB blow-up left no forensic trail. `MarpleLog` re-points
/// stdout/stderr at a rotating file so those lines survive. `MemoryPressureMonitor`
/// logs only when the OS reports pressure; `MemoryWatchdog` can still stamp the
/// app's own footprint on a fixed cadence when explicitly enabled for forensics.
///
/// This is diagnostics only: it changes no app behaviour, just makes the next
/// occurrence observable without a default periodic wakeup.
enum MarpleLog {
    /// `~/Library/Logs/Marple/marple.log`.
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/Marple/marple.log")
    }()

    /// Redirect stdout+stderr to `fileURL`, keeping line buffering so logs stream
    /// live. Rotates one generation at launch when the file exceeds `maxBytes`.
    static func redirectToFile(maxBytes: Int = 50 * 1024 * 1024) {
        let fm = FileManager.default
        let url = fileURL
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
            let prev = url.appendingPathExtension("1")
            try? fm.removeItem(at: prev)
            try? fm.moveItem(at: url, to: prev)
        }

        url.path.withCString { _ = freopen($0, "a", stdout) }
        url.path.withCString { _ = freopen($0, "a", stderr) }
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
        print("=== marple log session start \(stamp()) ===")
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func stamp() -> String { stampFormatter.string(from: Date()) }
}

/// Reads this process's real memory footprint (the figure Activity Monitor shows
/// under "Memory") via Mach `TASK_VM_INFO`. nil if the call fails.
func currentMemoryFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : nil
}

@MainActor
final class MemoryPressureMonitor {
    private var source: DispatchSourceMemoryPressure?

    func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { [weak self] in
            Task { @MainActor in self?.logPressure() }
        }
        s.activate()
        source = s
    }

    private func logPressure() {
        guard let bytes = currentMemoryFootprintBytes() else { return }
        let gb = Double(bytes) / 1_073_741_824
        print(String(format: "%@ [marple] memory pressure: footprint=%.2fGB",
                     MarpleLog.stamp(), gb))
    }
}

/// Stamps `footprint=<GB> entries=<n> refreshing=<bool>` into the log every
/// `interval` seconds; emits a loud `!!!` line each time footprint crosses a new
/// whole-GB mark above `warnGB`, so a runaway is caught at GB-by-GB resolution.
@MainActor
final class MemoryWatchdog {
    private var timer: Timer?
    private let interval: TimeInterval
    private let warnBytes: UInt64
    private var lastWarnGBStep: UInt64 = 0

    init(interval: TimeInterval = 15, warnGB: Double = 4) {
        self.interval = interval
        self.warnBytes = UInt64(warnGB * 1_073_741_824)
    }

    static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        defaults.bool(forKey: SettingsKeys.memoryWatchdogEnabled)
            || environment["MARPLE_MEMORY_WATCHDOG"] == "1"
            || arguments.contains("--memory-watchdog")
    }

    func start() {
        guard timer == nil, Self.isEnabled() else { return }
        tick()  // baseline line at launch
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let bytes = currentMemoryFootprintBytes() else { return }
        let gb = Double(bytes) / 1_073_741_824
        let m = ActiveModel.current
        let line = String(
            format: "[marple] mem: footprint=%.2fGB entries=%d refreshing=%@",
            gb, m?.entries.count ?? -1, (m?.isRefreshing ?? false) ? "yes" : "no")
        print("\(MarpleLog.stamp()) \(line)")

        if bytes > warnBytes {
            let step = bytes / 1_073_741_824
            if step > lastWarnGBStep {
                lastWarnGBStep = step
                print("\(MarpleLog.stamp()) [marple] !!! HIGH MEMORY \(line)")
            }
        }
    }
}
