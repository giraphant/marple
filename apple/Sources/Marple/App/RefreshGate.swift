import Foundation

/// QUA-198: single-flight gate for the reconcile→loadIndex chain.
/// `tryBegin` admits exactly one runner; later signals set a rerun flag instead
/// of starting a second chain. `finishOrRerun` consumes that flag — the runner
/// loops once more if anything arrived mid-run, then releases the gate.
///
/// QUA-212: the CLI surface shares this gate via `beginOrJoin` instead of
/// running its own ungated reconcile, which used to stack a duplicate full
/// vault walk back-to-back with the watcher/boot chain (serialized only by the
/// indexer writeLock — doubled first-search latency). A joiner waits for a
/// pass that STARTS after it joined: the in-flight walk may already have
/// passed the directory of a just-written file, so waiting for the current
/// pass wouldn't reliably self-heal the FSEvents race.
actor RefreshGate {
    private var running = false
    private var rerun = false
    /// Joiners waiting on the pass currently running.
    private var currentWaiters: [CheckedContinuation<Void, Never>] = []
    /// Joiners that arrived mid-pass, waiting on the trailing rerun.
    private var nextWaiters: [CheckedContinuation<Void, Never>] = []

    func tryBegin() -> Bool {
        if running { rerun = true; return false }
        running = true
        return true
    }

    func finishOrRerun() -> Bool {
        let finished = currentWaiters
        currentWaiters = []
        let again: Bool
        if rerun {
            rerun = false
            currentWaiters = nextWaiters
            nextWaiters = []
            again = true
        } else {
            running = false
            again = false
        }
        for waiter in finished { waiter.resume() }
        return again
    }

    /// Acquire the gate (returns true — the caller must run the chain and the
    /// `finishOrRerun` loop) or join the in-flight runner: request a trailing
    /// rerun and suspend until that fresh pass completes (returns false —
    /// nothing left to do, the index is at least as new as the join).
    func beginOrJoin() async -> Bool {
        if !running { running = true; return true }
        rerun = true
        await withCheckedContinuation { nextWaiters.append($0) }
        return false
    }

    /// Test hook: a trailing rerun has been requested on the active runner.
    var rerunRequested: Bool { rerun }
}
