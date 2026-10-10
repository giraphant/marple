import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@Suite @MainActor
struct TermIndexControllerTests {
    @Test func cliAndAutomaticRefreshUseSameIndex() async throws {
        let fixture = TermIndexTests()
        let root = try fixture.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try fixture.write(root, "a.md", """
        | 能动性 | agency | 行动 |
        | 能动性 | human agency | 另一对应 |
        | 效力与能动性的不对称 | efficacy / agency; asymmetrical-reciprocal relation | |
        """)
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let controller = TermIndexController(workspaceRoot: root.path)
        model.termIndexController = controller
        let indexer = VaultIndexer(workspaceRoot: root.path)
        let lookup = await CLIHandlers.handle(CLIRequest(method: CLIMethod.termsLookup, query: "能动性"),
            model: model, indexer: indexer)
        #expect(lookup.ok)
        #expect(Set(lookup.data?.termMatches?.map(\.term) ?? []) == ["agency", "human agency"])
        #expect(controller.status?.relations == 2)
        #expect(try await controller.index.lookup("效力与能动性的不对称").isEmpty)
        #expect(!controller.isRunning && controller.lastError == nil)
        let status = await CLIHandlers.handle(CLIRequest(method: CLIMethod.termsStatus), model: model, indexer: indexer)
        let decoded = try JSONDecoder().decode(CLIResponse.self, from: JSONEncoder().encode(status))
        #expect(decoded.data?.termStatus == controller.status)

        try fixture.write(root, "a.md", "| 惯习 | habitus | 倾向 |")
        // This is the same body called by the FSEvents watcher, even if the
        // ordinary index has no changed entries (or is unavailable).
        await model.refreshBody(0)
        _ = try await controller.refresh()
        #expect(try await controller.index.lookup("agency").isEmpty)
        #expect(try await controller.index.lookup("habitus").first?.term == "惯习")
        let rebuilt = await CLIHandlers.handle(CLIRequest(method: CLIMethod.termsRefresh, reset: true),
            model: model, indexer: indexer)
        #expect(rebuilt.ok && rebuilt.data?.termStatus?.relations == 1)
        let empty = await CLIHandlers.handle(CLIRequest(method: CLIMethod.termsLookup, query: "  "),
            model: model, indexer: indexer)
        #expect(empty.error?.code == CLIErrorCode.badRequest)
    }

    @Test func overlappingRefreshesJoinAndErrorsAreVisibleWithOldStatus() async throws {
        let fixture = TermIndexTests()
        let root = try fixture.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try fixture.write(root, "a.md", "| 具身性 | embodiment | 身体 |")
        let controller = TermIndexController(workspaceRoot: root.path)
        async let first = controller.refresh()
        async let second = controller.refresh(rebuild: true)
        let results = try await [first, second]
        #expect(results[0] == results[1])
        #expect(!controller.isRunning)
        let previous = controller.status
        try Data([0xFF, 0xFE, 0xFF]).write(to: root.appendingPathComponent("vault/z.md"))
        await #expect(throws: (any Error).self) { try await controller.refresh(rebuild: true) }
        #expect(controller.lastError != nil && !controller.isRunning)
        #expect(controller.status == previous)
        try FileManager.default.removeItem(at: root.appendingPathComponent("vault/z.md"))
        _ = try await controller.refresh()
        #expect(controller.lastError == nil)
    }
}
