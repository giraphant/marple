import Testing
@testable import MarpleKit

/// Pins the QUA-198/QUA-212 single-flight coalescing semantics relocated from
/// the Marple shell's `RefreshGate`. These assertions are the OOM-safety proxy:
/// concurrent vault-change signals must collapse to a bounded number of body
/// runs (one main pass + at most one trailing rerun) rather than stacking.
@Suite struct RefreshAuthorityTests {
    @Test func tryBeginAdmitsOneAndCoalescesRest() async {
        let a = RefreshAuthority()
        #expect(await a.tryBegin() == true)        // first admitted
        #expect(await a.tryBegin() == false)       // second coalesced (running) → rerun set
        #expect(await a.finishOrRerun() == true)   // rerun pending → loop
        #expect(await a.finishOrRerun() == false)  // nothing pending → release
    }

    @Test func tryBeginAfterReleaseAdmitsAgain() async {
        let a = RefreshAuthority()
        _ = await a.tryBegin()
        _ = await a.finishOrRerun()                // release
        #expect(await a.tryBegin() == true)        // fresh admit
    }

    @Test func concurrentSignalsRunBodyAtMostTwice() async {
        // OOM-safety proxy: N signals that all arrive WHILE a pass is running
        // collapse to ≤2 body executions (1 main + at most 1 trailing rerun),
        // never N stacked chains. We admit one runner, then fire 20 concurrent
        // tryBegin signals against the held gate (each coalesces into the single
        // rerun flag), and only then let the runner drain its loop.
        let a = RefreshAuthority()
        let counter = RefreshAuthorityCounter()
        #expect(await a.tryBegin())                 // one admitted runner holds the gate
        await counter.bump()                        // main pass body
        await withTaskGroup(of: Void.self) { g in   // 20 signals arrive mid-pass
            for _ in 0..<20 { g.addTask { _ = await a.tryBegin() } }
        }
        // Drain: at most one trailing rerun for all 20 coalesced signals.
        while await a.finishOrRerun() { await counter.bump() }
        let n = await counter.value
        #expect(n >= 1 && n <= 2)                   // coalesced: 1 main + at most 1 trailing
    }

    @Test func beginOrJoinAcquiresWhenIdle() async {
        // Idle gate → beginOrJoin acquires (returns true): the caller must run
        // the chain itself, mirroring tryBegin's admit.
        let a = RefreshAuthority()
        #expect(await a.beginOrJoin() == true)
        #expect(await a.finishOrRerun() == false)  // release
    }

    @Test func beginOrJoinSuspendsUntilTrailingRerunCompletes() async {
        // CLI joiner: when a pass is already running, beginOrJoin requests a
        // trailing rerun, suspends, and resumes — returning false (nothing left
        // to do) — only after that fresh pass has been run and released.
        let a = RefreshAuthority()
        _ = await a.tryBegin()                      // a pass is running
        let joinedFlag = RefreshAuthorityFlag()
        async let joined: Bool = {
            let r = await a.beginOrJoin()
            await joinedFlag.set()
            return r
        }()
        // Let the joiner enqueue, then confirm it is still suspended.
        await Task.yield()
        #expect(await joinedFlag.isSet == false)
        // The running pass finishes: rerun was requested by the joiner, so the
        // first finishOrRerun loops (true) and runs the trailing pass; the
        // second finishOrRerun releases and resumes the waiter (false).
        #expect(await a.finishOrRerun() == true)
        #expect(await a.finishOrRerun() == false)
        #expect(await joined == false)              // joiner returns false (it joined)
        #expect(await joinedFlag.isSet == true)
    }
}

actor RefreshAuthorityCounter {
    var value = 0
    func bump() { value += 1 }
}

actor RefreshAuthorityFlag {
    private(set) var isSet = false
    func set() { isSet = true }
}
