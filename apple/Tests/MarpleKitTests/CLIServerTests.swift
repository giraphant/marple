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

    @MainActor
    @Test func loadIndexRerunsActiveSearch() async throws {
        let note = Entry(path: "vault/notes/iphone2.md", type: .note, title: "搞你的 iPhone2",
                         author: [], year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let client = MutableVaultClient(entries: [], hits: [])
        let model = AppModel(client: client)
        model.select(pane: .type(.note))
        await model.loadIndex()
        model.setSearchText("iPhone2")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(model.visibleEntries.isEmpty)

        client.set(entries: [note], hits: [SearchHit(entry: note, score: 1, snippet: nil, source: "test")])
        await model.loadIndex()

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if model.visibleEntries.map(\.path) == [note.path] { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(model.visibleEntries.map(\.path) == [note.path])
    }

    private final class MutableVaultClient: VaultClient, @unchecked Sendable {
        private let queue = DispatchQueue(label: "MarpleKitTests.MutableVaultClient")
        private var currentEntries: [Entry]
        private var currentHits: [SearchHit]

        init(entries: [Entry], hits: [SearchHit]) {
            self.currentEntries = entries
            self.currentHits = hits
        }

        func set(entries: [Entry], hits: [SearchHit]) {
            queue.sync {
                currentEntries = entries
                currentHits = hits
            }
        }

        func index() async throws -> [Entry] {
            queue.sync { currentEntries }
        }

        func search(_ query: SearchQuery) async throws -> [SearchHit] {
            queue.sync { currentHits }
        }

        func entryText(path: String) async throws -> String { "" }
        func openInEditor(path: String, app: String) async throws {}
        func openPDF(slug: String) async throws {}
        func openTranslation(slug: String) async throws {}
        func hasTranslation(slug: String) -> Bool { false }
        func imageOriginalURL(forImageEntryPath path: String) async throws -> URL? { nil }
        func createImageObject(from sourceURL: URL, title: String?) async throws -> Entry { throw VaultError.notFound(sourceURL.path) }
        func writeFile(path: String, text: String) async throws {}
        func createNote(path: String, text: String) async throws {}
        func moveToTrash(path: String) async throws -> String { "" }
        func listTrash() async throws -> [TrashItem] { [] }
        func restoreTrash(name: String) async throws -> String { "" }
        func purgeTrash(name: String) async throws {}
    }

    private static func entry(_ path: String) -> Entry {
        Entry(path: path, type: .note, title: path, author: [], year: nil,
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
