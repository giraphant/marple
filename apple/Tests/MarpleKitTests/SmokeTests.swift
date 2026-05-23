import Testing
@testable import MarpleKit

@Suite struct SmokeTests {
    @Test func testVersion() { #expect(MarpleKitVersion.value == "0.1.0-p1") }
}
