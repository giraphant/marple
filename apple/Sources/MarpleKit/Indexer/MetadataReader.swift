import Foundation

/// Bounds waiting for filesystem metadata without pretending to cancel a stat.
/// Timed-out jobs keep their slot until the lookup returns; repeated requests
/// for that path join the same job. Saturation skips work instead of growing an
/// unbounded collection of blocked threads.
final class MetadataReader: @unchecked Sendable {
    private let lookup: @Sendable (String) -> Int64?
    private let timeout: TimeInterval
    // Serial GCD queues can make progress while Swift cooperative workers wait.
    // A concurrent global queue can starve behind those same waiting workers.
    private let workers: [DispatchQueue]
    private let lock = NSLock()
    private var availableWorkers: [Int]
    private var inFlight: [String: Job] = [:]

    // `value` is protected by the reader's lock, including after completion.
    private final class Job: @unchecked Sendable {
        let done = DispatchGroup()
        let worker: Int
        var value: Int64?
        init(worker: Int) { self.worker = worker; done.enter() }
    }

    init(timeout: TimeInterval = 0.25, maximumInFlight: Int = 4,
         lookup: @escaping @Sendable (String) -> Int64? = MetadataReader.fileMtimeMs) {
        self.lookup = lookup
        self.timeout = timeout
        self.workers = (0..<maximumInFlight).map {
            DispatchQueue(label: "marple.metadata.\($0)", qos: .utility)
        }
        self.availableWorkers = Array(0..<maximumInFlight)
    }

    func mtimeMs(atPath path: String) -> Int64? {
        let deadline = DispatchTime.now() + timeout
        let admission: (Job, Bool)? = lock.withLock {
            if let existing = inFlight[path] { return (existing, false) }
            guard let worker = availableWorkers.popLast() else { return nil }
            let job = Job(worker: worker)
            inFlight[path] = job
            return (job, true)
        }
        guard let (job, isNew) = admission else { return nil }
        if isNew {
            workers[job.worker].async { [self] in
                let value = lookup(path)
                lock.withLock {
                    job.value = value
                    inFlight.removeValue(forKey: path)
                    availableWorkers.append(job.worker)
                }
                job.done.leave()
            }
        }
        guard job.done.wait(timeout: deadline) == .success else { return nil }
        return lock.withLock { job.value }
    }

    static func fileMtimeMs(atPath path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
