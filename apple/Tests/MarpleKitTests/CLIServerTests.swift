import Foundation
import Testing
import Darwin
@testable import Marple
@testable import MarpleKit

@Suite struct CLIServerTests {
    @MainActor
    @Test func replaySurvivesLostResponseAndRejectsChangedPayload() async throws {
        let dir = URL(fileURLWithPath: "/tmp/cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("s.sock").path
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let server = CLIServer(socketPath: socketPath)
        let indexer = VaultIndexer(workspaceRoot: dir.path)
        try server.start(model: model, indexer: indexer)
        defer { server.stop() }
        let key = UUID().uuidString
        let first = try Self.keyedRequest(key: key, title: "必读 Essential")
        try await Task.detached { try Self.sendAndClose(first, socketPath: socketPath) }.value
        // Wait on observable state so response loss is known to occur AFTER
        // the first mutation reached the app, before asking for its replay.
        for _ in 0..<100 where model.tabGroups.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.tabGroups.count == 1)
        let retry = try Self.keyedRequest(key: key, title: "必读 Essential", retry: true)
        let response = try await Task.detached { try Self.roundTrip(retry, socketPath: socketPath) }.value
        #expect(response.ok)
        #expect(model.tabGroups.count == 1)
        #expect(response.data?.createdID == model.tabGroups.first?.id)
        let conflict = try Self.keyedRequest(key: key, title: "推荐 Recommended", retry: true)
        let rejected = try await Task.detached { try Self.roundTrip(conflict, socketPath: socketPath) }.value
        #expect(rejected.error?.code == "request_conflict")
        #expect(model.tabGroups.count == 1)

        server.stop()
        try server.start(model: model, indexer: indexer)
        let unknown = try await Task.detached { try Self.roundTrip(retry, socketPath: socketPath) }.value
        #expect(unknown.error?.code == "request_unknown")
        #expect(model.tabGroups.count == 1)
    }

    @MainActor
    @Test func concurrentMutationDuplicatesCreateOneFolder() async throws {
        let dir = URL(fileURLWithPath: "/tmp/cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("s.sock").path
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let server = CLIServer(socketPath: socketPath)
        try server.start(model: model, indexer: VaultIndexer(workspaceRoot: dir.path))
        defer { server.stop() }
        let request = try Self.keyedRequest(key: UUID().uuidString, title: "Concurrent")
        let responses = try await withThrowingTaskGroup(of: CLIResponse.self) { group in
            for _ in 0..<6 { group.addTask { try Self.roundTrip(request, socketPath: socketPath) } }
            var responses: [CLIResponse] = []
            for try await response in group { responses.append(response) }
            return responses
        }
        #expect(responses.allSatisfy { $0.ok })
        #expect(Set(responses.compactMap(\.data?.createdID)).count == 1)
        #expect(model.tabGroups.count == 1)
    }

    private static func keyedRequest(key: String, title: String, retry: Bool = false) throws -> CLIRequest {
        try JSONDecoder().decode(CLIRequest.self, from: JSONSerialization.data(withJSONObject: [
            "method": "mutate", "operation": "folders.create", "requestID": key,
            "retryOnly": retry, "title": title, "ids": []
        ]))
    }

    @MainActor
    @Test func organizationCommandsRoundTripOverSocket() async throws {
        let dir = URL(fileURLWithPath: "/tmp/cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("s.sock").path
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let server = CLIServer(socketPath: socketPath)
        try server.start(model: model, indexer: VaultIndexer(workspaceRoot: dir.path))
        defer { server.stop() }

        let created = try await Task.detached {
            try Self.roundTrip(CLIRequest(method: "folders.create", title: "Research"), socketPath: socketPath)
        }.value
        #expect(created.ok)
        let id = try #require(created.data?.createdID)
        let renamed = try await Task.detached {
            try Self.roundTrip(CLIRequest(method: "folders.rename", id: id.uuidString, title: "Sources"), socketPath: socketPath)
        }.value
        #expect(renamed.ok)
        let listed = try await Task.detached {
            try Self.roundTrip(CLIRequest(method: "tabs.list"), socketPath: socketPath)
        }.value
        #expect(listed.ok)
        #expect(listed.data?.tree?.first?.id == id)
        #expect(listed.data?.tree?.first?.title == "Sources")
        #expect(listed.data?.tree?.first?.children?.isEmpty == true)
        let invalid = try await Task.detached {
            try Self.roundTrip(CLIRequest(method: "folders.move", ids: [id.uuidString], parent: id.uuidString), socketPath: socketPath)
        }.value
        #expect(invalid.error?.code == CLIErrorCode.badRequest)
        #expect(model.tabGroups.map(\.id) == [id])
    }

    @MainActor
    @Test func pingDoesNotCrossMainActorFromAcceptQueue() throws {
        let dir = URL(fileURLWithPath: "/tmp/cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s.sock").path
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let indexer = VaultIndexer(workspaceRoot: dir.path)
        let server = CLIServer(socketPath: socketPath)
        try server.start(model: model, indexer: indexer)
        defer { server.stop() }

        let silentPeer = try Self.connectAndSend(nil, socketPath: socketPath)
        defer { close(silentPeer) }
        let completed = DispatchSemaphore(value: 0)
        let result = CLIResponseBox()
        DispatchQueue.global().async {
            result.set(try? Self.roundTrip(CLIRequest(method: CLIMethod.ping), socketPath: socketPath))
            completed.signal()
        }
        // Deliberately hold MainActor: a ping requiring it cannot complete here.
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(result.get()?.ok == true)
        #expect(result.get()?.data?.pong == "marple")
    }

    /// QUA-208: a client that times out and closes its socket before the
    /// response lands must not kill the app. Without SO_NOSIGPIPE on the
    /// accepted fd, the server's write raises SIGPIPE and the whole process
    /// dies (exit 141) — this test then kills the test runner itself.
    @MainActor
    @Test func clientClosingBeforeResponseDoesNotKillTheProcess() async throws {
        let dir = URL(fileURLWithPath: "/tmp/cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s.sock").path
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let indexer = VaultIndexer(workspaceRoot: dir.path)
        let server = CLIServer(socketPath: socketPath)
        try server.start(model: model, indexer: indexer)
        defer { server.stop() }

        // Send a request and slam the socket shut without reading the response,
        // like a marple-cli whose SO_RCVTIMEO expired.
        try await Task.detached {
            try Self.sendAndClose(CLIRequest(method: CLIMethod.ping), socketPath: socketPath)
        }.value
        // Give the server time to handle the request and write into the dead fd.
        try await Task.sleep(nanoseconds: 500_000_000)

        // Still alive? A fresh round-trip must succeed.
        let response = try await Task.detached {
            try Self.roundTrip(CLIRequest(method: CLIMethod.ping), socketPath: socketPath)
        }.value
        #expect(response.ok)
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
    @Test func readAcceptsAbsolutePathInsideWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-absolute-\(UUID().uuidString)")
        let relative = "vault/notes/absolute.md"
        let entry = Self.entry(relative)
        let model = AppModel(
            client: StubVaultClient(
                entries: [entry],
                texts: [relative: "---\ntype: note\n---\n\nBody"]),
            workspaceRoot: root.path
        )
        await model.loadIndex()

        let response = await CLIHandlers.handle(
            CLIRequest(
                method: CLIMethod.read,
                path: root.appendingPathComponent(relative).path),
            model: model,
            indexer: VaultIndexer(workspaceRoot: root.path)
        )

        #expect(response.ok)
        #expect(response.data?.entry?.digest.path == relative)
    }

    @MainActor
    @Test func coldOpenAcceptsAbsolutePathInsideWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-absolute-\(UUID().uuidString)")
        let relative = "vault/notes/absolute.md"
        let entry = Self.entry(relative)
        let model = AppModel(
            client: StubVaultClient(entries: [entry], texts: [relative: "Body"]),
            workspaceRoot: root.path
        )
        await model.loadIndex()

        try await model.cliOpenDocument(
            path: root.appendingPathComponent(relative).path)

        #expect(model.openPath == relative)
    }

    @MainActor
    @Test func absolutePathOutsideWorkspaceIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-root-\(UUID().uuidString)")
        let relative = "notes/outside.md"
        let entry = Self.entry(relative)
        let model = AppModel(
            client: StubVaultClient(entries: [entry], texts: [relative: "Outside"]),
            workspaceRoot: root.path
        )
        await model.loadIndex()
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("intruder/notes/outside.md").path

        let response = await CLIHandlers.handle(
            CLIRequest(method: CLIMethod.read, path: outside),
            model: model,
            indexer: VaultIndexer(workspaceRoot: root.path)
        )

        #expect(!response.ok)
        #expect(response.error?.code == CLIErrorCode.notFound)
        #expect(model.cliRelativePath(root.path) == nil)
    }

    /// Regression: an agent writes a vault file and immediately `open`s it,
    /// before the 0.4s-debounced FSEvents watcher has reconciled. The CLI must
    /// self-heal via a synchronous reconcile instead of returning
    /// "entry not in index". A path with no file on disk still returns notFound.
    @MainActor
    @Test func openSelfHealsFileWrittenAfterLastIndexLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-selfheal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("vault/papers"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let index = IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path)
        let client = LocalVaultClient(workspaceRoot: root.path, index: index)
        let indexer = VaultIndexer(workspaceRoot: root.path)
        let model = AppModel(client: client, workspaceRoot: root.path)
        model.cliIndexer = indexer

        // Index the empty vault — no target file exists yet.
        _ = try indexer.reconcile()
        await model.loadIndex()
        #expect(model.cliEntry(path: "vault/papers/new.md") == nil)

        // Agent writes the file directly; the watcher has NOT fired.
        try "---\ntype: paper\ntitle: New\n---\n\nbody".write(
            to: root.appendingPathComponent("vault/papers/new.md"), atomically: true, encoding: .utf8)

        let response = await CLIHandlers.handle(
            CLIRequest(method: "open", path: "vault/papers/new.md"), model: model, indexer: indexer)
        #expect(response.ok)
        #expect(model.openPath == "vault/papers/new.md")

        // A path with no file on disk stays notFound (genuine miss, not the race).
        let missing = await CLIHandlers.handle(
            CLIRequest(method: "open", path: "vault/papers/ghost.md"), model: model, indexer: indexer)
        #expect(missing.ok == false)
        #expect(missing.error?.code == CLIErrorCode.notFound)
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
        func fileURL(for path: String) -> URL? { nil }
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

    /// Connect to `socketPath` and send one request line. Caller owns the fd.
    private static func connectAndSend(_ request: CLIRequest?, socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

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
        guard connected == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard let request else { return fd }
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        try line.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                guard n > 0 else {
                    close(fd)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                sent += n
            }
        }
        return fd
    }

    /// Send a request, then close immediately without reading the response —
    /// the behavior of a marple-cli whose read timeout expired (QUA-208).
    private static func sendAndClose(_ request: CLIRequest, socketPath: String) throws {
        let fd = try connectAndSend(request, socketPath: socketPath)
        close(fd)
    }

    private static func roundTrip(_ request: CLIRequest, socketPath: String) throws -> CLIResponse {
        let fd = try connectAndSend(request, socketPath: socketPath)
        defer { close(fd) }

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

private final class CLIResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: CLIResponse?
    func set(_ value: CLIResponse?) { lock.withLock { response = value } }
    func get() -> CLIResponse? { lock.withLock { response } }
}
