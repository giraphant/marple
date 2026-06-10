import Foundation
import Testing
@testable import Marple

@Suite struct RefreshGateTests {
    /// QUA-198 semantics, unchanged: signals arriving mid-run collapse into
    /// exactly one trailing rerun, then the gate is reusable.
    @Test func signalsCollapseIntoOneTrailingRerun() async {
        let gate = RefreshGate()
        #expect(await gate.tryBegin())
        #expect(await gate.tryBegin() == false)
        #expect(await gate.tryBegin() == false)
        #expect(await gate.finishOrRerun())          // one rerun for both signals
        #expect(await gate.finishOrRerun() == false) // released
        #expect(await gate.tryBegin())               // reusable
        #expect(await gate.finishOrRerun() == false)
    }

    /// QUA-212: a joiner on an idle gate acquires it and must run the chain
    /// itself; a signal arriving mid-run still collapses into a rerun.
    @Test func idleJoinerAcquiresTheGate() async {
        let gate = RefreshGate()
        #expect(await gate.beginOrJoin())            // idle → CLI runs the chain
        #expect(await gate.tryBegin() == false)      // watcher signal collapses
        #expect(await gate.finishOrRerun())
        #expect(await gate.finishOrRerun() == false)
    }

    /// QUA-212: a joiner on a busy gate does NOT resume after the in-flight
    /// pass (which may have walked past a just-written file already) — it
    /// resumes only once the trailing rerun, a pass started after the join,
    /// completes.
    @Test func busyJoinerWaitsForAFreshPass() async {
        let gate = RefreshGate()
        #expect(await gate.tryBegin())               // watcher holds the gate

        let joiner = Task { await gate.beginOrJoin() }
        while !(await gate.rerunRequested) { await Task.yield() }

        #expect(await gate.finishOrRerun())          // pass 1 done → rerun owed
        #expect(await gate.finishOrRerun() == false) // pass 2 done → joiner freed
        #expect(await joiner.value == false)         // joined, never acquired
    }
}
