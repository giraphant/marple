# marple-native P1 (Walking Skeleton) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. When writing SwiftUI/AppKit code, first consult the `swiftui-expert` skill's `references/latest-apis.md` to avoid deprecated APIs.

**Goal:** A native macOS reader that lists 论文 (paper-analysis) entries, opens one into a natively-rendered Markdown reading view with tappable `[[wikilinks]]`, hands the file off to an external editor, and refreshes when that editor saves.

**Architecture:** A Swift Package at `apple/` with a logic library (`MarpleKit`, fully unit-tested) and a thin SwiftUI executable (`Marple`). All data flows through a `VaultClient` protocol; the P1 implementation `HTTPVaultClient` talks to the **existing** `reader-api` Rust binary, launched as a child process (`SidecarProcess`). The web app is untouched: nothing under `src/`, `index.html`, `rust/`, or the vite/tauri configs is modified.

**Tech Stack:** Swift 6 / SwiftUI (macOS 14+), Swift Package Manager, `swift-markdown` (cmark-gfm AST), XCTest, FSEvents (via `DispatchSource`), the existing Rust `reader-api` (Axum + SQLite).

**Reference contract (verified against the running backend):**
- `GET /api/index` → `{ "items": Entry[] }` — full index snapshot.
- `GET /vault/<rest>` → raw markdown text (entry body incl. frontmatter). `entry.path` is workspace-relative and already begins with `vault/`, so the URL is `<baseURL>/<entry.path>`.
- `POST /api/open-in-editor` JSON `{ "path": "vault/…md", "app": "" }` → opens in external editor (empty `app` = OS default).
- Sidecar config: env `MARPLE_ROOT` = directory holding `marple.config.json` (this repo); env `PORT` = bind port. Vault resolves from `marple.config.json`'s `workspaceRoot`.

---

## File Structure

All new files live under `apple/`. Nothing outside `apple/` and `docs/` is created or modified.

```
apple/
├── Package.swift                          # SPM manifest: MarpleKit lib + Marple exe + tests
├── .gitignore                             # ignore .build/
├── Sources/
│   ├── MarpleKit/                         # testable logic, no SwiftUI
│   │   ├── Entry.swift                    # Entry + EntryType DTOs (tolerant decode)
│   │   ├── VaultClient.swift              # protocol + VaultError + StubVaultClient
│   │   ├── HTTPVaultClient.swift          # concrete client over reader-api
│   │   ├── SidecarProcess.swift           # SidecarLaunch (pure) + SidecarProcess (spawn)
│   │   ├── Frontmatter.swift              # split(raw) -> (frontmatter, body)
│   │   ├── Wikilink.swift                 # protect/restore/tokenize -> [InlineToken]
│   │   ├── MarkdownModel.swift            # body -> [RenderBlock] via swift-markdown
│   │   └── VaultWatcher.swift             # FSEvents debounced change stream
│   └── Marple/                            # SwiftUI executable
│       ├── MarpleApp.swift                # @main, AppDelegate activation, sidecar wiring
│       ├── AppModel.swift                 # @Observable state hub
│       ├── SidebarView.swift             # type list + paper list
│       ├── DocView.swift                  # native markdown reader + open-in-editor button
│       └── MarkdownBlocksView.swift       # renders [RenderBlock] / [InlineToken]
└── Tests/
    └── MarpleKitTests/
        ├── EntryDecodeTests.swift
        ├── HTTPVaultClientTests.swift     # uses StubURLProtocol
        ├── SidecarLaunchTests.swift
        ├── FrontmatterTests.swift
        ├── WikilinkTests.swift
        ├── MarkdownModelTests.swift
        └── VaultWatcherTests.swift
```

**Shared type contract (defined in Task 2/3/6/7/8, referenced throughout):**

```swift
// Entry.swift
public enum EntryType: String, Codable, Sendable {
  case paperAnalysis = "paper-analysis", bookOverview = "book-overview",
       chapterSummary = "chapter-summary", authorProfile = "author-profile",
       topicSynthesis = "topic-synthesis", note = "note"
}
public struct Entry: Codable, Sendable, Identifiable, Equatable {
  public var id: String { path }
  public let path: String        // e.g. "vault/papers/foo.md"
  public let type: EntryType
  public let title: String?
  public let author: String?
  public let year: String?       // backend sends number|string|null
  public let ratingScore: Double // backend "rating_score"
  public let themes: [String]
  public let preview: String
  public let hasPDF: Bool        // backend "has_pdf"
}

// VaultClient.swift
public enum VaultError: Error, Equatable {
  case backendUnavailable, http(status: Int, body: String),
       notFound(String), decode(String)
}
public protocol VaultClient: Sendable {
  func index() async throws -> [Entry]
  func entryText(path: String) async throws -> String
  func openInEditor(path: String, app: String) async throws
}

// Wikilink.swift
public struct WikiRef: Equatable, Sendable { public let target: String; public let label: String }
public enum InlineToken: Equatable, Sendable {
  case text(String)
  case wikilink(target: String, label: String)
}

// MarkdownModel.swift
public enum RenderBlock: Equatable, Sendable {
  case heading(level: Int, [InlineToken])
  case paragraph([InlineToken])
  case bulletList([[InlineToken]])
  case orderedList([[InlineToken]])
  case quote([InlineToken])
  case codeBlock(language: String?, code: String)
  case thematicBreak
}
```

---

## Task 1: SPM project scaffold

**Files:**
- Create: `apple/Package.swift`
- Create: `apple/.gitignore`
- Create: `apple/Sources/MarpleKit/Placeholder.swift`
- Create: `apple/Sources/Marple/main_placeholder.swift`
- Create: `apple/Tests/MarpleKitTests/SmokeTests.swift`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Marple",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarpleKit", targets: ["MarpleKit"]),
        .executable(name: "Marple", targets: ["Marple"]),
    ],
    dependencies: [
        // swift-markdown ships via branch, not tagged release. If `main` fails to
        // resolve against the local toolchain, pin to the matching `release/x.y`.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "MarpleKit",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .executableTarget(
            name: "Marple",
            dependencies: ["MarpleKit"]
        ),
        .testTarget(
            name: "MarpleKitTests",
            dependencies: ["MarpleKit"]
        ),
    ]
)
```

- [ ] **Step 2: Write `.gitignore`**

```
.build/
*.xcodeproj
.swiftpm/
DerivedData/
```

- [ ] **Step 3: Write placeholder sources so the package compiles**

`apple/Sources/MarpleKit/Placeholder.swift`:
```swift
public enum MarpleKitVersion { public static let value = "0.1.0-p1" }
```

`apple/Sources/Marple/main_placeholder.swift`:
```swift
import MarpleKit
// Real @main lands in Task 13. This keeps the executable target compiling.
@main struct Bootstrap { static func main() { print(MarpleKitVersion.value) } }
```

`apple/Tests/MarpleKitTests/SmokeTests.swift`:
```swift
import XCTest
@testable import MarpleKit

final class SmokeTests: XCTestCase {
    func testVersion() { XCTAssertEqual(MarpleKitVersion.value, "0.1.0-p1") }
}
```

- [ ] **Step 4: Build and test**

Run: `cd apple && swift test`
Expected: build succeeds, `testVersion` PASSES. (First run downloads swift-markdown.)

- [ ] **Step 5: Commit**

```bash
git add apple/Package.swift apple/.gitignore apple/Sources apple/Tests
git commit -m "feat(native): scaffold apple/ SPM package (MarpleKit + Marple)"
```

---

## Task 2: Entry DTO with tolerant decoding

The backend sends snake_case keys and `year` as number **or** string **or** null; `themes` may be null; many fields may be absent. Decode defensively.

**Files:**
- Create: `apple/Sources/MarpleKit/Entry.swift`
- Test: `apple/Tests/MarpleKitTests/EntryDecodeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MarpleKit

final class EntryDecodeTests: XCTestCase {
    func decode(_ json: String) throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: Data(json.utf8))
    }

    func testDecodesNumberYearAndRating() throws {
        let entries = try decode("""
        [{"path":"vault/p/a.md","type":"paper-analysis","title":"A",
          "author":"Smith","year":2019,"rating_score":3.0,
          "themes":["x","y"],"preview":"hi","has_pdf":true}]
        """)
        XCTAssertEqual(entries.count, 1)
        let e = entries[0]
        XCTAssertEqual(e.type, .paperAnalysis)
        XCTAssertEqual(e.year, "2019")
        XCTAssertEqual(e.ratingScore, 3.0)
        XCTAssertEqual(e.themes, ["x","y"])
        XCTAssertTrue(e.hasPDF)
    }

    func testToleratesStringYearNullThemesMissingPdf() throws {
        let entries = try decode("""
        [{"path":"vault/n/b.md","type":"note","title":null,"author":null,
          "year":"forthcoming","rating_score":0,"themes":null,"preview":""}]
        """)
        let e = entries[0]
        XCTAssertEqual(e.type, .note)
        XCTAssertNil(e.title)
        XCTAssertEqual(e.year, "forthcoming")
        XCTAssertEqual(e.themes, [])
        XCTAssertFalse(e.hasPDF)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apple && swift test --filter EntryDecodeTests`
Expected: FAIL — `Entry` does not exist.

- [ ] **Step 3: Write `Entry.swift`**

```swift
import Foundation

public enum EntryType: String, Codable, Sendable {
    case paperAnalysis = "paper-analysis"
    case bookOverview = "book-overview"
    case chapterSummary = "chapter-summary"
    case authorProfile = "author-profile"
    case topicSynthesis = "topic-synthesis"
    case note = "note"
}

public struct Entry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let type: EntryType
    public let title: String?
    public let author: String?
    public let year: String?
    public let ratingScore: Double
    public let themes: [String]
    public let preview: String
    public let hasPDF: Bool

    enum CodingKeys: String, CodingKey {
        case path, type, title, author, year, preview
        case ratingScore = "rating_score"
        case themes
        case hasPDF = "has_pdf"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        type = try c.decode(EntryType.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        preview = (try? c.decodeIfPresent(String.self, forKey: .preview)) ?? "" ?? ""
        ratingScore = (try? c.decodeIfPresent(Double.self, forKey: .ratingScore)) ?? 0 ?? 0
        themes = (try? c.decodeIfPresent([String].self, forKey: .themes)) ?? [] ?? []
        hasPDF = (try? c.decodeIfPresent(Bool.self, forKey: .hasPDF)) ?? false ?? false
        // year: number | string | null
        if let s = try? c.decodeIfPresent(String.self, forKey: .year) {
            year = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .year) {
            year = String(i)
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .year) {
            year = String(Int(d))
        } else {
            year = nil
        }
    }

    public init(path: String, type: EntryType, title: String?, author: String?,
                year: String?, ratingScore: Double, themes: [String],
                preview: String, hasPDF: Bool) {
        self.path = path; self.type = type; self.title = title; self.author = author
        self.year = year; self.ratingScore = ratingScore; self.themes = themes
        self.preview = preview; self.hasPDF = hasPDF
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apple && swift test --filter EntryDecodeTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Entry.swift apple/Tests/MarpleKitTests/EntryDecodeTests.swift
git commit -m "feat(native): Entry DTO with tolerant decoding"
```

---

## Task 3: VaultClient protocol, VaultError, and a stub

**Files:**
- Create: `apple/Sources/MarpleKit/VaultClient.swift`
- Test: covered indirectly; add one stub-roundtrip test here.
- Test: `apple/Tests/MarpleKitTests/VaultClientStubTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MarpleKit

final class VaultClientStubTests: XCTestCase {
    func testStubReturnsSeededEntries() async throws {
        let e = Entry(path: "vault/p/a.md", type: .paperAnalysis, title: "A",
                      author: nil, year: nil, ratingScore: 0, themes: [],
                      preview: "", hasPDF: false)
        let client: VaultClient = StubVaultClient(entries: [e], texts: ["vault/p/a.md": "# A"])
        let idx = try await client.index()
        XCTAssertEqual(idx, [e])
        let body = try await client.entryText(path: "vault/p/a.md")
        XCTAssertEqual(body, "# A")
    }

    func testStubMissingTextThrowsNotFound() async {
        let client: VaultClient = StubVaultClient(entries: [], texts: [:])
        do { _ = try await client.entryText(path: "nope.md"); XCTFail("expected throw") }
        catch let err as VaultError { XCTAssertEqual(err, .notFound("nope.md")) }
        catch { XCTFail("wrong error \(error)") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apple && swift test --filter VaultClientStubTests`
Expected: FAIL — `VaultClient` / `StubVaultClient` undefined.

- [ ] **Step 3: Write `VaultClient.swift`**

```swift
import Foundation

public enum VaultError: Error, Equatable {
    case backendUnavailable
    case http(status: Int, body: String)
    case notFound(String)
    case decode(String)
}

public protocol VaultClient: Sendable {
    func index() async throws -> [Entry]
    func entryText(path: String) async throws -> String
    func openInEditor(path: String, app: String) async throws
}

public struct StubVaultClient: VaultClient {
    public let entries: [Entry]
    public let texts: [String: String]
    public init(entries: [Entry], texts: [String: String]) {
        self.entries = entries; self.texts = texts
    }
    public func index() async throws -> [Entry] { entries }
    public func entryText(path: String) async throws -> String {
        guard let t = texts[path] else { throw VaultError.notFound(path) }
        return t
    }
    public func openInEditor(path: String, app: String) async throws {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apple && swift test --filter VaultClientStubTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/VaultClient.swift apple/Tests/MarpleKitTests/VaultClientStubTests.swift
git commit -m "feat(native): VaultClient protocol + error + stub"
```

---

## Task 4: HTTPVaultClient over reader-api

Uses a custom `URLProtocol` to intercept requests in tests, so no live server is needed.

**Files:**
- Create: `apple/Sources/MarpleKit/HTTPVaultClient.swift`
- Test: `apple/Tests/MarpleKitTests/HTTPVaultClientTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
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

final class HTTPVaultClientTests: XCTestCase {
    func makeClient() -> HTTPVaultClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return HTTPVaultClient(baseURL: URL(string: "http://localhost:9999")!,
                               session: URLSession(configuration: cfg))
    }

    func testIndexParsesItems() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/index")
            let body = #"{"items":[{"path":"vault/a.md","type":"note","preview":"","rating_score":0}]}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let entries = try await makeClient().index()
        XCTAssertEqual(entries.map(\.path), ["vault/a.md"])
    }

    func testEntryTextHitsVaultPathAndReturnsRawBody() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/vault/papers/x.md")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("---\ntitle: X\n---\n# X".utf8))
        }
        let text = try await makeClient().entryText(path: "vault/papers/x.md")
        XCTAssertTrue(text.contains("# X"))
    }

    func testOpenInEditorPostsJSON() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/open-in-editor")
            XCTAssertEqual(req.httpMethod, "POST")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        try await makeClient().openInEditor(path: "vault/papers/x.md", app: "")
    }

    func testNon200MapsToHTTPError() async {
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data("missing".utf8))
        }
        do { _ = try await makeClient().entryText(path: "vault/none.md"); XCTFail() }
        catch let e as VaultError { XCTAssertEqual(e, .http(status: 404, body: "missing")) }
        catch { XCTFail("wrong error") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apple && swift test --filter HTTPVaultClientTests`
Expected: FAIL — `HTTPVaultClient` undefined.

- [ ] **Step 3: Write `HTTPVaultClient.swift`**

```swift
import Foundation

public struct HTTPVaultClient: VaultClient {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private func get(_ path: String) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        return try await run(URLRequest(url: url))
    }

    private func run(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw VaultError.backendUnavailable }
        guard let http = response as? HTTPURLResponse else { throw VaultError.backendUnavailable }
        guard (200..<300).contains(http.statusCode) else {
            throw VaultError.http(status: http.statusCode,
                                  body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    public func index() async throws -> [Entry] {
        let data = try await get("api/index")
        struct Wrapper: Decodable { let items: [Entry] }
        do { return try JSONDecoder().decode(Wrapper.self, from: data).items }
        catch { throw VaultError.decode("\(error)") }
    }

    public func entryText(path: String) async throws -> String {
        // entry.path already starts with "vault/", so it maps onto GET /vault/*.
        let data = try await get(path)
        return String(decoding: data, as: UTF8.self)
    }

    public func openInEditor(path: String, app: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/open-in-editor"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["path": path, "app": app])
        _ = try await run(req)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apple && swift test --filter HTTPVaultClientTests`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/HTTPVaultClient.swift apple/Tests/MarpleKitTests/HTTPVaultClientTests.swift
git commit -m "feat(native): HTTPVaultClient over reader-api"
```

---

## Task 5: SidecarLaunch config + SidecarProcess spawn

Split pure config (unit-tested) from the side-effecting spawn (manually validated).

**Files:**
- Create: `apple/Sources/MarpleKit/SidecarProcess.swift`
- Test: `apple/Tests/MarpleKitTests/SidecarLaunchTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MarpleKit

final class SidecarLaunchTests: XCTestCase {
    func testFreePortIsInUserRange() throws {
        let p = try SidecarLaunch.freePort()
        XCTAssertGreaterThan(p, 1024)
    }

    func testArgumentsRunReaderApiRelease() {
        let args = SidecarLaunch.arguments(repoRoot: "/repo")
        XCTAssertEqual(args, ["run", "--release",
                              "--manifest-path", "/repo/rust/Cargo.toml",
                              "-p", "reader-api"])
    }

    func testEnvironmentSetsMarpleRootAndPort() {
        let env = SidecarLaunch.environment(repoRoot: "/repo", port: 5544)
        XCTAssertEqual(env["MARPLE_ROOT"], "/repo")
        XCTAssertEqual(env["PORT"], "5544")
    }

    func testBaseURLForPort() {
        XCTAssertEqual(SidecarLaunch.baseURL(port: 5544).absoluteString,
                       "http://localhost:5544")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apple && swift test --filter SidecarLaunchTests`
Expected: FAIL — `SidecarLaunch` undefined.

- [ ] **Step 3: Write `SidecarProcess.swift`**

```swift
import Foundation

public enum SidecarLaunch {
    /// Bind to port 0, read the OS-assigned port, release it. Small TOCTOU window
    /// is acceptable: the sidecar re-binds immediately on launch.
    public static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VaultError.backendUnavailable }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw VaultError.backendUnavailable }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    public static func arguments(repoRoot: String) -> [String] {
        ["run", "--release", "--manifest-path", "\(repoRoot)/rust/Cargo.toml",
         "-p", "reader-api"]
    }

    public static func environment(repoRoot: String, port: UInt16) -> [String: String] {
        ["MARPLE_ROOT": repoRoot, "PORT": String(port)]
    }

    public static func baseURL(port: UInt16) -> URL {
        URL(string: "http://localhost:\(port)")!
    }
}

public final class SidecarProcess {
    private let repoRoot: String
    private let cargoPath: String
    private var process: Process?
    public private(set) var baseURL: URL?

    public init(repoRoot: String, cargoPath: String = "/usr/bin/env") {
        self.repoRoot = repoRoot
        self.cargoPath = cargoPath
    }

    /// Spawn reader-api and poll until /api/index answers (or time out).
    public func start(readinessTimeout: TimeInterval = 60) async throws -> URL {
        let port = try SidecarLaunch.freePort()
        let url = SidecarLaunch.baseURL(port: port)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cargoPath)
        // `/usr/bin/env cargo run …` resolves cargo from PATH.
        p.arguments = ["cargo"] + SidecarLaunch.arguments(repoRoot: repoRoot)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in SidecarLaunch.environment(repoRoot: repoRoot, port: port) { env[k] = v }
        p.environment = env
        try p.run()
        self.process = p
        self.baseURL = url

        let deadline = Date().addingTimeInterval(readinessTimeout)
        while Date() < deadline {
            if await probe(url) { return url }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        stop()
        throw VaultError.backendUnavailable
    }

    private func probe(_ url: URL) async -> Bool {
        var req = URLRequest(url: url.appendingPathComponent("api/index"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    deinit { stop() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apple && swift test --filter SidecarLaunchTests`
Expected: PASS (all four).

- [ ] **Step 5: Manual integration check (real sidecar)**

Run this throwaway snippet via a scratch test or `swift run` once Task 13 exists; for now verify the cargo command works standalone:
Run: `MARPLE_ROOT="$(pwd)" PORT=5599 cargo run --release --manifest-path rust/Cargo.toml -p reader-api`
Expected: prints `reader api at http://localhost:5599`; `curl -s localhost:5599/api/index | head -c 80` returns JSON beginning `{"items":`. Ctrl+C to stop.

- [ ] **Step 6: Commit**

```bash
git add apple/Sources/MarpleKit/SidecarProcess.swift apple/Tests/MarpleKitTests/SidecarLaunchTests.swift
git commit -m "feat(native): sidecar launch config + spawn/readiness"
```

---

## Task 6: Frontmatter splitter

Strip the leading `---…---` fence so the reader renders only the body. Mirrors the regex used in the web app (`src/api.ts:replaceBody`).

**Files:**
- Create: `apple/Sources/MarpleKit/Frontmatter.swift`
- Test: `apple/Tests/MarpleKitTests/FrontmatterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MarpleKit

final class FrontmatterTests: XCTestCase {
    func testSplitsLeadingFence() {
        let raw = "---\ntitle: X\nthemes: []\n---\n# Heading\n\nBody."
        let r = Frontmatter.split(raw)
        XCTAssertEqual(r.frontmatter, "title: X\nthemes: []")
        XCTAssertEqual(r.body, "# Heading\n\nBody.")
    }

    func testNoFenceReturnsWholeBody() {
        let raw = "# Just a body\n\nNo frontmatter."
        let r = Frontmatter.split(raw)
        XCTAssertNil(r.frontmatter)
        XCTAssertEqual(r.body, raw)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apple && swift test --filter FrontmatterTests`
Expected: FAIL — `Frontmatter` undefined.

- [ ] **Step 3: Write `Frontmatter.swift`**

```swift
import Foundation

public enum Frontmatter {
    public static func split(_ raw: String) -> (frontmatter: String?, body: String) {
        guard raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else { return (nil, raw) }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // lines[0] == "---" (possibly with trailing \r). Find the next closing "---".
        var closing: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closing = i; break
        }
        guard let end = closing else { return (nil, raw) }
        let fm = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fm, body.trimmingCharacters(in: CharacterSet(charactersIn: "\n")))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apple && swift test --filter FrontmatterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Frontmatter.swift apple/Tests/MarpleKitTests/FrontmatterTests.swift
git commit -m "feat(native): frontmatter splitter"
```

---

## Task 7: Wikilink tokenizer

`[[target]]` and `[[target|label]]` → `InlineToken`s. `protect`/`restore` keep wikilinks out of cmark's reach (Task 8 parses the protected text, then restores).

**Files:**
- Create: `apple/Sources/MarpleKit/Wikilink.swift`
- Test: `apple/Tests/MarpleKitTests/WikilinkTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MarpleKit

final class WikilinkTests: XCTestCase {
    func testPlainTextIsOneTextToken() {
        XCTAssertEqual(Wikilink.tokenize("just text"), [.text("just text")])
    }

    func testSingleWikilink() {
        XCTAssertEqual(Wikilink.tokenize("see [[Foo]] now"),
                       [.text("see "), .wikilink(target: "Foo", label: "Foo"), .text(" now")])
    }

    func testPipedLabel() {
        XCTAssertEqual(Wikilink.tokenize("[[foo/bar.md|Bar]]"),
                       [.wikilink(target: "foo/bar.md", label: "Bar")])
    }

    func testProtectRestoreRoundTrip() {
        let (protected, refs) = Wikilink.protect("a [[X]] b")
        XCTAssertFalse(protected.contains("[["))
        XCTAssertEqual(Wikilink.restore(protected, refs),
                       [.text("a "), .wikilink(target: "X", label: "X"), .text(" b")])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apple && swift test --filter WikilinkTests`
Expected: FAIL — `Wikilink` undefined.

- [ ] **Step 3: Write `Wikilink.swift`**

```swift
import Foundation

public struct WikiRef: Equatable, Sendable {
    public let target: String
    public let label: String
}

public enum InlineToken: Equatable, Sendable {
    case text(String)
    case wikilink(target: String, label: String)
}

public enum Wikilink {
    // Private-use sentinel cmark passes through untouched.
    private static let mark = "\u{F8FF}"
    private static let regex = try! NSRegularExpression(pattern: #"\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]"#)

    public static func protect(_ s: String) -> (protected: String, refs: [String: WikiRef]) {
        var refs: [String: WikiRef] = [:]
        var out = ""
        var last = s.startIndex
        var n = 0
        let ns = s as NSString
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: s) else { continue }
            out += s[last..<r.lowerBound]
            let target = ns.substring(with: m.range(at: 1))
            let labelRange = m.range(at: 2)
            let label = labelRange.location == NSNotFound ? target : ns.substring(with: labelRange)
            let key = "\(mark)\(n)\(mark)"
            refs[key] = WikiRef(target: target.trimmingCharacters(in: .whitespaces),
                                label: label.trimmingCharacters(in: .whitespaces))
            out += key
            n += 1
            last = r.upperBound
        }
        out += s[last...]
        return (out, refs)
    }

    public static func restore(_ s: String, _ refs: [String: WikiRef]) -> [InlineToken] {
        guard !refs.isEmpty else { return s.isEmpty ? [] : [.text(s)] }
        var tokens: [InlineToken] = []
        var buffer = ""
        var i = s.startIndex
        func flush() { if !buffer.isEmpty { tokens.append(.text(buffer)); buffer = "" } }
        while i < s.endIndex {
            if s[i] == Character(mark) {
                // read up to the next mark
                if let close = s[s.index(after: i)...].firstIndex(of: Character(mark)) {
                    let key = String(s[i...close])
                    if let ref = refs[key] {
                        flush()
                        tokens.append(.wikilink(target: ref.target, label: ref.label))
                        i = s.index(after: close)
                        continue
                    }
                }
            }
            buffer.append(s[i])
            i = s.index(after: i)
        }
        flush()
        return tokens
    }

    public static func tokenize(_ s: String) -> [InlineToken] {
        let (p, refs) = protect(s)
        return restore(p, refs)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apple && swift test --filter WikilinkTests`
Expected: PASS (all four).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Wikilink.swift apple/Tests/MarpleKitTests/WikilinkTests.swift
git commit -m "feat(native): wikilink tokenizer (protect/restore)"
```

---

## Task 8: MarkdownModel — body → [RenderBlock]

Parse the body with swift-markdown for block structure; restore wikilinks per block via Task 7. P1 flattens inline emphasis to plain text (styled emphasis is a P2 upgrade); wikilinks are preserved and navigable.

**Files:**
- Create: `apple/Sources/MarpleKit/MarkdownModel.swift`
- Test: `apple/Tests/MarpleKitTests/MarkdownModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MarpleKit

final class MarkdownModelTests: XCTestCase {
    func testHeadingAndParagraph() {
        let blocks = MarkdownModel.blocks(from: "# Title\n\nA paragraph.")
        XCTAssertEqual(blocks, [
            .heading(level: 1, [.text("Title")]),
            .paragraph([.text("A paragraph.")]),
        ])
    }

    func testParagraphKeepsWikilink() {
        let blocks = MarkdownModel.blocks(from: "See [[Foo]] here.")
        XCTAssertEqual(blocks, [
            .paragraph([.text("See "), .wikilink(target: "Foo", label: "Foo"), .text(" here.")]),
        ])
    }

    func testBulletList() {
        let blocks = MarkdownModel.blocks(from: "- one\n- two")
        XCTAssertEqual(blocks, [
            .bulletList([[.text("one")], [.text("two")]]),
        ])
    }

    func testCodeBlock() {
        let blocks = MarkdownModel.blocks(from: "```swift\nlet x = 1\n```")
        XCTAssertEqual(blocks, [.codeBlock(language: "swift", code: "let x = 1\n")])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apple && swift test --filter MarkdownModelTests`
Expected: FAIL — `MarkdownModel` undefined.

- [ ] **Step 3: Write `MarkdownModel.swift`**

```swift
import Foundation
import Markdown

public enum RenderBlock: Equatable, Sendable {
    case heading(level: Int, [InlineToken])
    case paragraph([InlineToken])
    case bulletList([[InlineToken]])
    case orderedList([[InlineToken]])
    case quote([InlineToken])
    case codeBlock(language: String?, code: String)
    case thematicBreak
}

public enum MarkdownModel {
    public static func blocks(from body: String) -> [RenderBlock] {
        let (protected, refs) = Wikilink.protect(body)
        let document = Document(parsing: protected)
        var blocks: [RenderBlock] = []
        for child in document.children {
            appendBlock(child, refs: refs, into: &blocks)
        }
        return blocks
    }

    private static func inline(_ markup: Markup, _ refs: [String: WikiRef]) -> [InlineToken] {
        Wikilink.restore(markup.plainTextProtected, refs)
    }

    private static func appendBlock(_ markup: Markup, refs: [String: WikiRef],
                                    into blocks: inout [RenderBlock]) {
        switch markup {
        case let h as Heading:
            blocks.append(.heading(level: h.level, inline(h, refs)))
        case let p as Paragraph:
            blocks.append(.paragraph(inline(p, refs)))
        case let list as UnorderedList:
            blocks.append(.bulletList(list.listItems.map { inline($0, refs) }))
        case let list as OrderedList:
            blocks.append(.orderedList(list.listItems.map { inline($0, refs) }))
        case let q as BlockQuote:
            blocks.append(.quote(inline(q, refs)))
        case let code as CodeBlock:
            let lang = code.language?.isEmpty == false ? code.language : nil
            blocks.append(.codeBlock(language: lang, code: code.code))
        case is ThematicBreak:
            blocks.append(.thematicBreak)
        default:
            // Unknown/unsupported block → render its visible text as a paragraph
            // so nothing is silently dropped (P2 adds tables/images).
            let text = markup.plainTextProtected
            if !text.isEmpty { blocks.append(.paragraph(Wikilink.restore(text, refs))) }
        }
    }
}

private extension Markup {
    /// `plainText` strips emphasis markers but preserves our F8FF sentinels
    /// (they are plain text to cmark), so wikilinks survive into restore().
    var plainTextProtected: String { self.format() == self.format() ? plainTextValue : plainTextValue }
    var plainTextValue: String {
        var s = ""
        collectText(self, into: &s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func collectText(_ markup: Markup, into s: inout String) {
    if let t = markup as? Text { s += t.string; return }
    if let c = markup as? InlineCode { s += c.code; return }
    if markup is SoftBreak || markup is LineBreak { s += " "; return }
    for child in markup.children { collectText(child, into: &s) }
}
```

> Note: `plainTextProtected` keeps the implementation honest — it walks the inline tree collecting only visible text (and inline-code), which leaves the `\u{F8FF}` sentinels intact for `Wikilink.restore`. The redundant `format()` guard is removed in the next step if the linter flags it; functionally it returns `plainTextValue`.

Simplify the extension to avoid the dead guard:

```swift
private extension Markup {
    var plainTextProtected: String {
        var s = ""
        collectText(self, into: &s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apple && swift test --filter MarkdownModelTests`
Expected: PASS (all four). If `CodeBlock.code` includes/excludes the trailing newline differently on the resolved swift-markdown version, adjust the test's expected `code` to match the library's actual output (run once, read the diff, set the literal).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/MarkdownModel.swift apple/Tests/MarpleKitTests/MarkdownModelTests.swift
git commit -m "feat(native): markdown model (blocks + wikilinks)"
```

---

## Task 9: VaultWatcher — debounced FSEvents change stream

Watches the workspace `vault/` directory; coalesces bursts; calls a handler. The debounce coalescer is unit-tested; the FSEvents wiring is manually validated in Task 13.

**Files:**
- Create: `apple/Sources/MarpleKit/VaultWatcher.swift`
- Test: `apple/Tests/MarpleKitTests/VaultWatcherTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MarpleKit

final class VaultWatcherTests: XCTestCase {
    func testCoalescerFiresOnceAfterBurst() async {
        let fired = Coalescer.Box()
        let c = Coalescer(interval: 0.05) { await fired.bump() }
        c.signal(); c.signal(); c.signal()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let n = await fired.count
        XCTAssertEqual(n, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apple && swift test --filter VaultWatcherTests`
Expected: FAIL — `Coalescer` undefined.

- [ ] **Step 3: Write `VaultWatcher.swift`**

```swift
import Foundation

/// Collapses a burst of signals into a single trailing-edge call.
public final class Coalescer: @unchecked Sendable {
    public actor Box {
        public private(set) var count = 0
        public init() {}
        public func bump() { count += 1 }
    }
    private let interval: TimeInterval
    private let action: @Sendable () async -> Void
    private var workItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "marple.coalescer")

    public init(interval: TimeInterval, action: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.action = action
    }

    public func signal() {
        queue.async { [weak self] in
            guard let self else { return }
            self.workItem?.cancel()
            let item = DispatchWorkItem { Task { await self.action() } }
            self.workItem = item
            self.queue.asyncAfter(deadline: .now() + self.interval, execute: item)
        }
    }
}

/// FSEvents-backed directory watcher. Recursive watch via a kqueue/DispatchSource
/// on the directory file descriptor is coarse; for a deep vault we watch the
/// directory and reconcile on any event (the server already diffs by mtime).
public final class VaultWatcher {
    private let url: URL
    private let coalescer: Coalescer
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    public init(vaultDirectory: URL, debounce: TimeInterval = 0.4,
                onChange: @escaping @Sendable () async -> Void) {
        self.url = vaultDirectory
        self.coalescer = Coalescer(interval: debounce, action: onChange)
    }

    public func start() {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global())
        src.setEventHandler { [weak self] in self?.coalescer.signal() }
        src.setCancelHandler { [weak self] in if let fd = self?.fd, fd >= 0 { close(fd) } }
        src.resume()
        self.source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
```

> Note: a `DispatchSource` on a single directory fd sees changes to that directory's entries, not nested files. For P1 the open document lives where the editor writes it; if nested-dir granularity is needed, the executable can also re-fetch the open doc on window-focus (cheap). The server-side watcher already keeps the index itself current.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apple && swift test --filter VaultWatcherTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/VaultWatcher.swift apple/Tests/MarpleKitTests/VaultWatcherTests.swift
git commit -m "feat(native): debounced vault watcher"
```

---

## Task 10: AppModel + Sidebar + paper ListView

`AppModel` is the `@Observable` state hub. Sidebar lists 论文 entries; selecting one sets the open path. (Single-tab navigation in P1; multi-tab is P3.)

**Files:**
- Create: `apple/Sources/Marple/AppModel.swift`
- Create: `apple/Sources/Marple/SidebarView.swift`
- Test: `apple/Tests/MarpleKitTests/` — wikilink resolution is logic; add it to MarpleKit instead (below).

- [ ] **Step 1: Write the failing test (wikilink resolution lives in MarpleKit)**

Create `apple/Tests/MarpleKitTests/ResolveTests.swift`:
```swift
import XCTest
@testable import MarpleKit

final class ResolveTests: XCTestCase {
    let entries = [
        Entry(path: "vault/papers/foo.md", type: .paperAnalysis, title: "Foo Paper",
              author: nil, year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false),
        Entry(path: "vault/notes/bar.md", type: .note, title: "Bar",
              author: nil, year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false),
    ]
    func testResolveByTitle() {
        XCTAssertEqual(WikiResolver.resolve("Foo Paper", in: entries)?.path, "vault/papers/foo.md")
    }
    func testResolveByPathStem() {
        XCTAssertEqual(WikiResolver.resolve("bar", in: entries)?.path, "vault/notes/bar.md")
    }
    func testUnresolvedIsNil() {
        XCTAssertNil(WikiResolver.resolve("nothing", in: entries))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apple && swift test --filter ResolveTests`
Expected: FAIL — `WikiResolver` undefined.

- [ ] **Step 3: Add `WikiResolver` to MarpleKit**

Append to `apple/Sources/MarpleKit/Wikilink.swift`:
```swift
public enum WikiResolver {
    public static func resolve(_ target: String, in entries: [Entry]) -> Entry? {
        let needle = target.lowercased()
        if let byTitle = entries.first(where: { ($0.title ?? "").lowercased() == needle }) {
            return byTitle
        }
        return entries.first { entry in
            let stem = (entry.path as NSString).lastPathComponent
                .replacingOccurrences(of: ".md", with: "").lowercased()
            return stem == needle
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apple && swift test --filter ResolveTests`
Expected: PASS.

- [ ] **Step 5: Write `AppModel.swift`**

```swift
import Foundation
import MarpleKit
import Observation

@Observable @MainActor
final class AppModel {
    let client: VaultClient
    var entries: [Entry] = []
    var openPath: String?
    var openBlocks: [RenderBlock] = []
    var status: String = ""

    init(client: VaultClient) { self.client = client }

    var papers: [Entry] {
        entries.filter { $0.type == .paperAnalysis }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    func loadIndex() async {
        do { entries = try await client.index(); status = "\(entries.count) entries" }
        catch { status = "index failed: \(error)" }
    }

    func open(_ path: String) async {
        openPath = path
        do {
            let raw = try await client.entryText(path: path)
            openBlocks = MarkdownModel.blocks(from: Frontmatter.split(raw).body)
        } catch { openBlocks = [.paragraph([.text("load failed: \(error)")])] }
    }

    func reloadOpen() async { if let p = openPath { await open(p) } }

    func follow(_ target: String) async {
        if let hit = WikiResolver.resolve(target, in: entries) { await open(hit.path) }
        else { status = "unresolved [[\(target)]]" }
    }

    func openExternally() async {
        guard let p = openPath else { return }
        do { try await client.openInEditor(path: p, app: "") }
        catch { status = "open-in-editor failed: \(error)" }
    }
}
```

- [ ] **Step 6: Write `SidebarView.swift`**

```swift
import SwiftUI
import MarpleKit

struct SidebarView: View {
    @Bindable var model: AppModel
    var body: some View {
        List(model.papers, selection: Binding(
            get: { model.openPath },
            set: { if let p = $0 { Task { await model.open(p) } } }
        )) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? "(untitled)").font(.headline).lineLimit(2)
                if let a = entry.author { Text(a).font(.caption).foregroundStyle(.secondary) }
            }
            .tag(entry.path)
        }
        .navigationTitle("论文 (\(model.papers.count))")
    }
}
```

- [ ] **Step 7: Build**

Run: `cd apple && swift build`
Expected: builds (the executable still uses the Task 1 placeholder `@main`; that's replaced in Task 13).

- [ ] **Step 8: Commit**

```bash
git add apple/Sources/Marple/AppModel.swift apple/Sources/Marple/SidebarView.swift apple/Sources/MarpleKit/Wikilink.swift apple/Tests/MarpleKitTests/ResolveTests.swift
git commit -m "feat(native): AppModel + sidebar paper list + wiki resolver"
```

---

## Task 11: DocView — native markdown reader + open-in-editor

Renders `[RenderBlock]`; wikilinks are tappable and call `model.follow`; a toolbar button hands the file to the external editor.

**Files:**
- Create: `apple/Sources/Marple/MarkdownBlocksView.swift`
- Create: `apple/Sources/Marple/DocView.swift`

- [ ] **Step 1: Write `MarkdownBlocksView.swift`**

```swift
import SwiftUI
import MarpleKit

struct InlineTextView: View {
    let tokens: [InlineToken]
    let onFollow: (String) -> Void
    var body: some View {
        tokens.reduce(Text("")) { acc, token in
            switch token {
            case .text(let s): return acc + Text(s)
            case .wikilink(_, let label):
                return acc + Text(label).foregroundColor(.accentColor).underline()
            }
        }
        // Tap handling: a Text concatenation can't route per-run taps, so expose
        // each wikilink as a button row beneath dense paragraphs is overkill in P1.
        // Instead, render wikilink-bearing lines via the tappable flow below.
    }
}

/// A flow that renders text runs inline and wikilinks as tappable buttons.
struct InlineFlow: View {
    let tokens: [InlineToken]
    let onFollow: (String) -> Void
    var body: some View {
        WrapHStack(tokens.indices.map { $0 }, id: \.self) { i in
            switch tokens[i] {
            case .text(let s):
                Text(s)
            case .wikilink(let target, let label):
                Button(label) { onFollow(target) }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
            }
        }
    }
}

/// Minimal wrapping HStack good enough for P1 inline flow.
struct WrapHStack<Data: RandomAccessCollection, Content: View>: View
where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content
    init(_ data: Data, id: KeyPath<Data.Element, Data.Element> = \.self,
         @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data; self.content = content
    }
    var body: some View {
        // P1: simple horizontal run; long paragraphs wrap at the window edge via
        // SwiftUI's default Text wrapping when tokens are mostly text. For dense
        // wikilink paragraphs this lays out left-to-right and wraps per-run.
        FlexibleView(data: data, content: content)
    }
}

/// Lightweight flexible wrap layout (iOS/macOS 14 Layout API).
struct FlexibleView<Data: RandomAccessCollection, Content: View>: View
where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content
    var body: some View {
        FlowLayout {
            ForEach(Array(data), id: \.self) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

struct BlockView: View {
    let block: RenderBlock
    let onFollow: (String) -> Void
    var body: some View {
        switch block {
        case .heading(let level, let tokens):
            InlineFlow(tokens: tokens, onFollow: onFollow)
                .font(headingFont(level)).bold().padding(.top, 8)
        case .paragraph(let tokens):
            InlineFlow(tokens: tokens, onFollow: onFollow)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•"); InlineFlow(tokens: items[i], onFollow: onFollow)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1)."); InlineFlow(tokens: items[i], onFollow: onFollow)
                    }
                }
            }
        case .quote(let tokens):
            InlineFlow(tokens: tokens, onFollow: onFollow)
                .padding(.leading, 12).overlay(alignment: .leading) {
                    Rectangle().frame(width: 3).foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
        case .codeBlock(_, let code):
            Text(code).font(.system(.body, design: .monospaced))
                .padding(8).background(.quaternary).cornerRadius(6)
        case .thematicBreak:
            Divider().padding(.vertical, 8)
        }
    }
    func headingFont(_ level: Int) -> Font {
        switch level { case 1: return .title; case 2: return .title2; case 3: return .title3; default: return .headline }
    }
}
```

- [ ] **Step 2: Write `DocView.swift`**

```swift
import SwiftUI
import MarpleKit

struct DocView: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if model.openPath == nil {
                ContentUnavailableView("选择一篇论文", systemImage: "doc.text")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.openBlocks.indices, id: \.self) { i in
                            BlockView(block: model.openBlocks[i]) { target in
                                Task { await model.follow(target) }
                            }
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("用外部编辑器打开") { Task { await model.openExternally() } }
                    .disabled(model.openPath == nil)
            }
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `cd apple && swift build`
Expected: builds. (Consult `swiftui-expert` `references/latest-apis.md` if any API here is flagged deprecated on the local toolchain — e.g. swap `.cornerRadius` for `.clipShape(.rect(cornerRadius:))` if warned.)

- [ ] **Step 4: Commit**

```bash
git add apple/Sources/Marple/MarkdownBlocksView.swift apple/Sources/Marple/DocView.swift
git commit -m "feat(native): native markdown reader + open-in-editor button"
```

---

## Task 12: App entry — wire sidecar, model, window, watcher refresh

Replace the placeholder `@main`. On launch: spawn the sidecar, build `HTTPVaultClient`, load the index, show `NavigationSplitView(Sidebar | DocView)`, and start the `VaultWatcher` to reload the open doc on external save.

**Files:**
- Delete: `apple/Sources/Marple/main_placeholder.swift`
- Create: `apple/Sources/Marple/MarpleApp.swift`

- [ ] **Step 1: Delete the placeholder main**

```bash
rm apple/Sources/Marple/main_placeholder.swift
```

- [ ] **Step 2: Write `MarpleApp.swift`**

```swift
import SwiftUI
import AppKit
import MarpleKit

final class AppState: ObservableObject {
    let sidecar: SidecarProcess
    @Published var model: AppModel?
    @Published var booting = true
    @Published var bootError: String?
    private var watcher: VaultWatcher?

    init(repoRoot: String) {
        self.sidecar = SidecarProcess(repoRoot: repoRoot)
    }

    @MainActor
    func boot(repoRoot: String, vaultDir: URL) async {
        do {
            let base = try await sidecar.start()
            let client = HTTPVaultClient(baseURL: base)
            let m = AppModel(client: client)
            await m.loadIndex()
            self.model = m
            self.booting = false
            let watcher = VaultWatcher(vaultDirectory: vaultDir) { [weak m] in
                await m?.reloadOpen()
            }
            watcher.start()
            self.watcher = watcher
        } catch {
            self.bootError = "\(error)"
            self.booting = false
        }
    }
}

@main
struct MarpleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state: AppState

    // P1 dev config: this repo holds rust/ and marple.config.json; the vault is
    // resolved by reader-api from marple.config.json's workspaceRoot.
    static let repoRoot = "/Users/ramudai/Documents/Learn/marple"
    static let vaultDir = URL(fileURLWithPath: "/Users/ramudai/Documents/Learn/bts/vault")

    init() {
        _state = StateObject(wrappedValue: AppState(repoRoot: MarpleApp.repoRoot))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = state.model {
                    NavigationSplitView {
                        SidebarView(model: model).frame(minWidth: 260)
                    } detail: {
                        DocView(model: model)
                    }
                } else if state.booting {
                    ProgressView("启动 reader-api…").padding()
                } else {
                    ContentUnavailableView("启动失败", systemImage: "exclamationmark.triangle",
                                           description: Text(state.bootError ?? "unknown"))
                }
            }
            .task {
                await state.boot(repoRoot: MarpleApp.repoRoot, vaultDir: MarpleApp.vaultDir)
            }
            .frame(minWidth: 900, minHeight: 600)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running a SwiftUI app from `swift run` needs an explicit activation
        // policy + activate so the window comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 3: Build**

Run: `cd apple && swift build`
Expected: builds with no errors.

- [ ] **Step 4: Manual end-to-end validation (golden path)**

Pre-req: the vault at `marple.config.json`'s `workspaceRoot` has a built index (`npm run build:index` once, if not already present).

Run: `cd apple && swift run Marple`
Verify, in order:
1. Window appears; after a few seconds the sidebar lists 论文 entries (count > 0).
2. Click a paper → the reading pane renders headings/paragraphs/lists (not raw markdown, no `---` frontmatter).
3. A `[[wikilink]]` in the body is colored/underlined; clicking it switches the reading pane to the linked entry (or sets status "unresolved" if no match).
4. Click **用外部编辑器打开** → the `.md` opens in the OS default markdown app.
5. In that editor, change a heading, save. Within ~1s the reading pane reflects the edit (watcher → reloadOpen).
6. Quit the app → confirm `reader-api` is gone: `pgrep -fl reader-api` prints nothing.

Record results inline in the PR/commit message. If step 5 doesn't fire (nested-file granularity), note it and rely on re-selecting the entry — full FSEvents tree watching is a follow-up.

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/Marple/MarpleApp.swift
git rm apple/Sources/Marple/main_placeholder.swift
git commit -m "feat(native): app entry — sidecar boot, split view, watcher refresh"
```

---

## Task 13: Verify the web build is untouched + document P1

Confirms the hard constraint: the existing web app still builds and nothing outside `apple/`/`docs/` changed.

**Files:**
- Modify: `README.md` (append a short native-app dev note)

- [ ] **Step 1: Confirm no web files changed**

Run: `git log --oneline --name-only origin/main..HEAD | grep -vE '^(apple/|docs/|[0-9a-f]{7} )' | grep -v '^$' || echo "OK: only apple/ and docs/ touched"`
Expected: `OK: only apple/ and docs/ touched` (plus the README line added in Step 3).

- [ ] **Step 2: Confirm the web app still typechecks/builds**

Run: `npm run typecheck`
Expected: passes (the native work added no TypeScript).

- [ ] **Step 3: Append a native dev note to README**

Add under the existing run section:
```markdown
## Native macOS reader (experimental, P1)

A SwiftUI reader lives in `apple/` and reuses this repo's `reader-api` as a
sidecar (no web changes). Requires a built index at the configured
`workspaceRoot`.

```sh
cd apple && swift test     # MarpleKit logic tests
cd apple && swift run Marple   # launch the reader (spawns reader-api)
```
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): note experimental native macOS reader (P1)"
```

---

## Self-Review

**Spec coverage (against `2026-05-23-marple-native-reader-design.md`):**
- §1 positioning (reader, editing outsourced): Tasks 11–12 (open-in-editor + watcher). ✓
- §3 architecture (SwiftUI UI → VaultClient → reader-core): Tasks 3–4, 10–12. ✓
- §4 VaultClient boundary + B2 sidecar + boundary discipline (async/throws, transport-free UI, independent DTOs): Tasks 2–5. ✓
- §5 native swift-markdown reading view + tappable wikilinks + (P1 subset) : Tasks 7, 8, 11. Scroll-spy outline and typography settings are P3 (out of P1 scope). ✓ (scoped)
- §6 metadata + file-management writes: **out of P1** (P3/P4); P1 only reads + open-in-editor. Intentional.
- §7 external handoff + FSEvents refresh: Tasks 11–12. ✓
- §11 P1 definition (sidebar + 论文 list → open → native reader w/ wikilink → open-in-editor + watcher): Tasks 10–12. ✓
- "Do not break the web UI": Tasks 1 (isolated `apple/`) + 13 (verification). ✓

**Placeholder scan:** No "TBD/handle errors/similar to". The one prose simplification in Task 8 (removing the dead `format()` guard) is shown as explicit replacement code, not a placeholder.

**Type consistency:** `Entry`, `EntryType`, `VaultClient`/`VaultError`, `InlineToken`/`WikiRef`, `RenderBlock`, `SidecarLaunch`/`SidecarProcess`, `Coalescer`/`VaultWatcher`, `AppModel` (methods `loadIndex`/`open`/`follow`/`reloadOpen`/`openExternally`), `WikiResolver.resolve` — all defined before use and referenced with consistent signatures.

**Known P1 limitations (deliberate, deferred):** inline emphasis flattened to plain text (P2); single-tab navigation, no history (P3); FSEvents granularity is directory-level (re-select as fallback); hardcoded dev `repoRoot`/`vaultDir` constants (a first-run picker is a fast-follow). swift-markdown is pinned by branch — if it fails to resolve, switch to a matching `release/x.y` branch.
