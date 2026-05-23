import Foundation

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

/// FSEvents-backed directory watcher via a DispatchSource on the directory fd.
/// Coarse by design: it only hints "something changed"; the handler decides what
/// to refresh (the VaultIndexer reconciles by mtime diff on each signal).
public final class VaultWatcher: @unchecked Sendable {
    private let url: URL
    private let coalescer: Coalescer
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    public init(vaultDirectory: URL, debounce: TimeInterval = 0.4,
                onChange: @escaping @Sendable () async -> Void) {
        self.url = vaultDirectory
        self.coalescer = Coalescer(interval: debounce, action: onChange)
    }

    public func start() {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global())
        src.setEventHandler { [weak self] in self?.coalescer.signal() }
        src.setCancelHandler { [weak self] in if let fd = self?.fd, fd >= 0 { close(fd) } }
        src.resume()
        self.source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
