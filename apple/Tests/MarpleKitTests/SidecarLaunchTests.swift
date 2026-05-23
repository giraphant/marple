import Testing
@testable import MarpleKit

@Suite struct SidecarLaunchTests {
    @Test func testFreePortIsInUserRange() throws {
        let p = try SidecarLaunch.freePort()
        #expect(p > 1024)
    }

    @Test func testArgumentsRunReaderApiRelease() {
        let args = SidecarLaunch.arguments(repoRoot: "/repo")
        #expect(args == ["run", "--release",
                         "--manifest-path", "/repo/rust/Cargo.toml",
                         "-p", "reader-api"])
    }

    @Test func testEnvironmentSetsMarpleRootAndPort() {
        let env = SidecarLaunch.environment(repoRoot: "/repo", port: 5544)
        #expect(env["MARPLE_ROOT"] == "/repo")
        #expect(env["PORT"] == "5544")
    }

    @Test func testBaseURLForPort() {
        #expect(SidecarLaunch.baseURL(port: 5544).absoluteString == "http://localhost:5544")
    }
}
