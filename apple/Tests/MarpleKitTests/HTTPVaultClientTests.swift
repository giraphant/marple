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
