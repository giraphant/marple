import Foundation
import Testing
@testable import MarpleKit

@Suite struct VaultWatcherTests {
    @Test func testCoalescerFiresOnceAfterBurst() async {
        let fired = Coalescer.Box()
        let c = Coalescer(interval: 0.05) { await fired.bump() }
        c.signal(); c.signal(); c.signal()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let n = await fired.count
        #expect(n == 1)
    }
}
