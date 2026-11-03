import Foundation
import Testing
@testable import Marple

struct QuasiConfigTests {
    @Test func decodesDynamicKeysAndOptionalMetadata() throws {
        let json = #"""
        {"store":"macOS Keychain","service":"quasi","keys":[
          {"name":"future_agent","env":"QUASI_FUTURE_AGENT","group":"写手","secret":false,"description":"写手框架","set":false,"source":null,"choices":["codex","claude"],"default":"codex"},
          {"name":"token","env":"QUASI_TOKEN","group":"接口","secret":true,"description":"令牌","set":true,"source":"keychain"},
          {"name":"url","env":"QUASI_URL","group":"接口","secret":false,"description":"地址","set":true,"source":"env","value":"https://example.com"},
          {"name":"legacy","env":"QUASI_LEGACY","group":"接口","secret":false,"description":"无默认值","set":false,"source":null}
        ]}
        """#
        let config = try JSONDecoder().decode(QuasiConfiguration.self, from: Data(json.utf8))
        #expect(config.service == "quasi")
        #expect(config.keys.map(\.group) == ["写手", "接口", "接口", "接口"])
        #expect(config.keys[0].choices == ["codex", "claude"])
        #expect(config.keys[0].displayedValue == "codex")
        #expect(config.keys[1].displayedValue == "")
        #expect(config.keys[1].set)
        #expect(config.keys[2].source == "env")
        #expect(config.keys[2].displayedValue == "https://example.com")
        #expect(config.keys[3].default == nil)
        #expect(config.keys[3].displayedValue == "")
    }

    @Test func valuesTravelOnlyOnStdinAndUnsetHasNoValue() async throws {
        let root = try fixture("""
        #!/bin/sh
        cd "$(dirname "$0")"
        printf '%s\\n' "$@" > arguments
        cat > input
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = QuasiConfigClient(executablePath: root.appendingPathComponent("fake quasi").path)
        let value = "secret with spaces ' \" $HOME $(exit 99); & | \\"
        try await client.set("new_key", value: value)
        #expect(try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8) == "config\nset\nnew_key\n")
        #expect(try String(contentsOf: root.appendingPathComponent("input"), encoding: .utf8) == value + "\n")
        try await client.unset("new_key")
        #expect(try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8) == "config\nunset\nnew_key\n")
        #expect(try Data(contentsOf: root.appendingPathComponent("input")).isEmpty)
    }

    @Test func showAndFailures() async throws {
        let root = try fixture("""
        #!/bin/sh
        [ "$*" = "config show --json" ] || exit 2
        printf '%s' '{"store":"macOS Keychain","service":"quasi","keys":[]}'
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("fake quasi")
        let client = QuasiConfigClient(executablePath: path.path)
        #expect(try await client.show().keys.isEmpty)
        try "#!/bin/sh\nprintf 'not json'\n".write(to: path, atomically: false, encoding: .utf8)
        do {
            _ = try await client.show()
            Issue.record("Malformed JSON should fail")
        } catch { #expect(error.localizedDescription.contains("JSON")) }
        try "#!/bin/sh\nprintf '配置值不合法' >&2\nexit 2\n".write(to: path, atomically: false, encoding: .utf8)
        do {
            try await client.set("new_key", value: "x")
            Issue.record("Nonzero exit should fail")
        } catch { #expect(error.localizedDescription == "配置值不合法") }
        try FileManager.default.removeItem(at: path)
        do {
            _ = try await client.show()
            Issue.record("Missing executable should fail")
        } catch { #expect(error.localizedDescription.contains("scripts/quasi")) }
    }

    @Test func discoversFirstExistingCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(QuasiConfigClient.discoverPath(home: root) == nil)
        for relative in ["Vibe/quasi/scripts/quasi", ".claude/skills/quasi/scripts/quasi", ".agents/skills/quasi/scripts/quasi"] {
            let path = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: path)
            #expect(QuasiConfigClient.discoverPath(home: root) == path.path)
        }
    }

    private func fixture(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuasiConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("fake quasi")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return root
    }
}
