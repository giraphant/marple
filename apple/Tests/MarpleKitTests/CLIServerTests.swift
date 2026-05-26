import Foundation
import Testing
import Darwin
@testable import Marple
@testable import MarpleKit

@Suite struct CLIServerTests {
    @MainActor
    @Test func pingDoesNotCrossMainActorFromAcceptQueue() async throws {
        let dir = URL(fileURLWithPath: "/tmp/cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s.sock").path
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let indexer = VaultIndexer(workspaceRoot: dir.path)
        let server = CLIServer(socketPath: socketPath)
        try server.start(model: model, indexer: indexer)
        defer { server.stop() }

        let response = try await Task.detached {
            try Self.roundTrip(CLIRequest(method: CLIMethod.ping), socketPath: socketPath)
        }.value

        #expect(response.ok)
        #expect(response.data?.pong == "marple")
    }

    @MainActor
    @Test func openCreatesDocumentPageEvenWhenReaderIsActive() async throws {
        let first = Self.entry("vault/notes/first.md")
        let second = Self.entry("vault/notes/second.md")
        let model = AppModel(client: StubVaultClient(
            entries: [first, second],
            texts: [first.path: "---\ntype: note\n---\n\nFirst", second.path: "---\ntype: note\n---\n\nSecond"]
        ))
        await model.loadIndex()
        await model.open(first.path)

        let response = await CLIHandlers.handle(
            CLIRequest(method: "open", path: second.path),
            model: model,
            indexer: VaultIndexer(workspaceRoot: "/tmp")
        )

        #expect(response.ok)
        #expect(response.data?.opened == true)
        #expect(model.tabs.map(\.location.openPath) == [first.path, second.path])
        #expect(model.openPath == second.path)
    }

    @MainActor
    @Test func openActivatesExistingDocumentPageWithoutDuplicating() async throws {
        let first = Self.entry("vault/notes/first.md")
        let second = Self.entry("vault/notes/second.md")
        let model = AppModel(client: StubVaultClient(
            entries: [first, second],
            texts: [first.path: "---\ntype: note\n---\n\nFirst", second.path: "---\ntype: note\n---\n\nSecond"]
        ))
        await model.loadIndex()
        await model.open(first.path)
        await model.openInNewTab(second.path)

        let response = await CLIHandlers.handle(
            CLIRequest(method: "open", path: first.path),
            model: model,
            indexer: VaultIndexer(workspaceRoot: "/tmp")
        )

        #expect(response.ok)
        #expect(model.tabs.map(\.location.openPath) == [first.path, second.path])
        #expect(model.openPath == first.path)
    }

    @MainActor
    @Test func retiredCliMethodsAreRejected() async {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let indexer = VaultIndexer(workspaceRoot: "/tmp")
        let retired = [
            "refresh",
            "list",
            "tag.add",
            "tag.remove",
            "frontmatter.set",
            "open.theme",
            "open.entry",
        ]

        for method in retired {
            let response = await CLIHandlers.handle(CLIRequest(method: method), model: model, indexer: indexer)
            #expect(response.ok == false)
            #expect(response.error?.code == CLIErrorCode.badRequest)
        }
    }

    private static func entry(_ path: String) -> Entry {
        Entry(path: path, type: .note, title: path, author: nil, year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }

    private static func roundTrip(_ request: CLIRequest, socketPath: String) throws -> CLIResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        try #require(pathBytes.count < cap)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        try line.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                sent += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            response.append(chunk, count: n)
            if response.last == 0x0A { break }
        }
        try #require(!response.isEmpty)
        if response.last == 0x0A { response.removeLast() }
        return try JSONDecoder().decode(CLIResponse.self, from: response)
    }
}
