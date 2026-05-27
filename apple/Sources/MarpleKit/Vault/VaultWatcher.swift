import Foundation
import CoreServices

/// Collapses a burst of signals into a single trailing-edge call.
public final class Coalescer: @unchecked Sendable {
    public actor Box {
        public private(set) var count = 0
        public init() {}
        public func bump() { count += 1 }
    }
    private let interval: TimeInterval
    private let action: @Sendable () async -> Void
    private var workItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "marple.coalescer")

    public init(interval: TimeInterval, action: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.action = action
    }

    public func signal() {
        queue.async { [weak self] in
            guard let self else { return }
            self.workItem?.cancel()
            let item = DispatchWorkItem { Task { await self.action() } }
            self.workItem = item
            self.queue.asyncAfter(deadline: .now() + self.interval, execute: item)
        }
    }
}

/// Recursive FSEvents-backed watcher for the vault directory.
/// Coarse by design: it only hints "something changed"; the handler decides what
/// to refresh (the VaultIndexer reconciles by mtime diff on each signal).
public final class VaultWatcher: @unchecked Sendable {
    private final class CallbackContext: @unchecked Sendable {
        let coalescer: Coalescer
        init(coalescer: Coalescer) { self.coalescer = coalescer }
    }

    private static let contextRetain: CFAllocatorRetainCallBack = { info in
        guard let info else { return nil }
        _ = Unmanaged<CallbackContext>.fromOpaque(info).retain()
        return info
    }

    private static let contextRelease: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<CallbackContext>.fromOpaque(info).release()
    }

    private static let streamCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue().coalescer.signal()
    }

    private let url: URL
    private let coalescer: Coalescer
    private let queue = DispatchQueue(label: "marple.vault-watcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(vaultDirectory: URL, debounce: TimeInterval = 0.4,
                onChange: @escaping @Sendable () async -> Void) {
        self.url = vaultDirectory
        self.coalescer = Coalescer(interval: debounce, action: onChange)
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }
        let callbackContext = CallbackContext(coalescer: coalescer)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: Self.contextRetain,
            release: Self.contextRelease,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.streamCallback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
