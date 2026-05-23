import Testing
import Foundation
@testable import MarpleKit

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        guard let h = StubURLProtocol.handler else { fatalError("no handler") }
        let (resp, data) = h(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension URLRequest {
    /// URLProtocol receives the body as a stream; read whichever is present.
    func bodyData() -> Data {
        if let b = httpBody { return b }
        guard let s = httpBodyStream else { return Data() }
        s.open(); defer { s.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while s.hasBytesAvailable {
            let n = s.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

@Suite(.serialized) struct HTTPVaultClientTests {
    func makeClient() -> HTTPVaultClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return HTTPVaultClient(baseURL: URL(string: "http://localhost:9999")!,
                               session: URLSession(configuration: cfg))
    }

    @Test func testIndexParsesItems() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/index")
            let body = #"{"items":[{"path":"vault/a.md","type":"note","preview":"","rating_score":0}]}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let entries = try await makeClient().index()
        #expect(entries.map(\.path) == ["vault/a.md"])
    }

    @Test func testEntryTextHitsVaultPathAndReturnsRawBody() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/vault/papers/x.md")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("---\ntitle: X\n---\n# X".utf8))
        }
        let text = try await makeClient().entryText(path: "vault/papers/x.md")
        #expect(text.contains("# X"))
    }

    @Test func testOpenInEditorPostsJSON() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/open-in-editor")
            #expect(req.httpMethod == "POST")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        try await makeClient().openInEditor(path: "vault/papers/x.md", app: "")
    }

    @Test func testSearchBuildsQueryAndDecodesHits() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/search")
            let qs = req.url?.query ?? ""
            #expect(qs.contains("q=marx"))
            #expect(qs.contains("mode=fast"))
            #expect(qs.contains("entry_type=paper-analysis"))
            let body = #"{"items":[{"entry":{"path":"vault/p/a.md","type":"paper-analysis","preview":"","rating_score":0},"score":7.5,"snippet":"hi","source":"fulltext"}]}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let hits = try await makeClient().search(SearchQuery(q: "marx", type: .paperAnalysis))
        #expect(hits.map { $0.entry.path } == ["vault/p/a.md"])
        #expect(hits.first?.score == 7.5)
        #expect(hits.first?.source == "fulltext")
    }

    @Test func testWriteFilePutsFullText() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.path == "/vault/notes/n.md")
            #expect(String(decoding: req.bodyData(), as: UTF8.self) == "new text")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        try await makeClient().writeFile(path: "vault/notes/n.md", text: "new text")
    }

    @Test func testCreateNotePostsText() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/vault/notes/new.md")
            #expect(String(decoding: req.bodyData(), as: UTF8.self) == "hello")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true,"path":"vault/notes/new.md"}"#.utf8))
        }
        try await makeClient().createNote(path: "vault/notes/new.md", text: "hello")
    }

    @Test func testMoveToTrashDeletesAndReturnsTrashPath() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.path == "/vault/notes/old.md")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true,"trash":"vault/notes/.trash/old.2026.md"}"#.utf8))
        }
        let p = try await makeClient().moveToTrash(path: "vault/notes/old.md")
        #expect(p == "vault/notes/.trash/old.2026.md")
    }

    @Test func testListTrashParsesItems() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/trash")
            let body = #"{"items":[{"name":"old.2026.md","originalBase":"old","ts":"2026","mtime":1.0,"size":5}]}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let items = try await makeClient().listTrash()
        #expect(items.map(\.name) == ["old.2026.md"])
    }

    @Test func testRestoreTrashPostsAndReturnsRestored() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/trash/old.2026.md/restore")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true,"restored":"vault/notes/old.md"}"#.utf8))
        }
        let r = try await makeClient().restoreTrash(name: "old.2026.md")
        #expect(r == "vault/notes/old.md")
    }

    @Test func testPurgeTrashDeletes() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.path == "/api/trash/old.2026.md")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        try await makeClient().purgeTrash(name: "old.2026.md")
    }

    @Test func testNon200MapsToHTTPError() async {
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data("missing".utf8))
        }
        do {
            _ = try await makeClient().entryText(path: "vault/none.md")
            Issue.record("expected throw")
        } catch let e as VaultError {
            #expect(e == .http(status: 404, body: "missing"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}
