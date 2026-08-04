# Marple CLI Absolute Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `marple-cli read` and `marple-cli open` accept vault-internal absolute paths while preserving existing relative-path behavior.

**Architecture:** Normalize user-supplied paths inside `AppModel`, the only layer that owns the configured workspace root. Convert a standardized absolute path under that root into the relative path already used by the index; reject all other absolute paths without changing the wire protocol or index.

**Tech Stack:** Swift 6, Swift Argument Parser, Swift Testing, MarpleKit/AppKit app target.

## Global Constraints

- Keep the index and CLI wire protocol relative-path based.
- Continue accepting existing workspace-relative paths unchanged.
- Reject workspace-root and outside-workspace absolute paths with the existing `not_found` response.
- Cover both live socket requests and cold-start `marple://open` fallback.
- Add no new dependency or configuration.

---

### Task 1: Normalize CLI document paths at the app boundary

**Files:**
- Modify: `apple/Tests/MarpleKitTests/CLIServerTests.swift`
- Modify: `apple/Sources/Marple/CLI/AppModel+CLI.swift`
- Modify: `apple/Sources/Marple/CLI/CLIHandlers.swift`
- Modify: `apple/Sources/marple-cli/main.swift`

**Interfaces:**
- Consumes: `AppModel.workspaceRoot`, canonical `Entry.path` values, and existing `CLIRequest.path` strings.
- Produces: `AppModel.cliRelativePath(_ path: String) -> String?`, returning the canonical relative key or `nil` for an invalid absolute path.

- [ ] **Step 1: Write failing behavior tests**

Add tests using an `AppModel` whose workspace root is a fresh temporary directory and whose stub client contains `vault/notes/absolute.md`:

```swift
@MainActor
@Test func readAcceptsAbsolutePathInsideWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli-absolute-\(UUID().uuidString)")
    let relative = "vault/notes/absolute.md"
    let entry = Self.entry(relative)
    let model = AppModel(
        client: StubVaultClient(entries: [entry], texts: [relative: "---\ntype: note\n---\n\nBody"]),
        workspaceRoot: root.path
    )
    await model.loadIndex()

    let response = await CLIHandlers.handle(
        CLIRequest(method: CLIMethod.read, path: root.appendingPathComponent(relative).path),
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

    try await model.cliOpenDocument(path: root.appendingPathComponent(relative).path)

    #expect(model.openPath == relative)
}

@MainActor
@Test func absolutePathsOutsideWorkspaceAreRejected() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli-root-\(UUID().uuidString)")
    let model = AppModel(client: StubVaultClient(entries: [], texts: [:]), workspaceRoot: root.path)

    let outside = root.deletingLastPathComponent().appendingPathComponent("outside.md").path
    let response = await CLIHandlers.handle(
        CLIRequest(method: CLIMethod.read, path: outside),
        model: model,
        indexer: VaultIndexer(workspaceRoot: root.path)
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.notFound)
    #expect(model.cliRelativePath(root.path) == nil)
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
cd apple
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter CLIServerTests
```

Expected: the new absolute-path assertions fail because requests still use the absolute string as an index key, and `cliRelativePath` does not exist yet.

- [ ] **Step 3: Implement the minimal path normalizer**

Add to `AppModel+CLI.swift`:

```swift
func cliRelativePath(_ path: String) -> String? {
    guard path.hasPrefix("/") else { return path }
    guard !workspaceRoot.isEmpty else { return nil }

    let rootComponents = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        .standardizedFileURL.pathComponents
    let targetComponents = URL(fileURLWithPath: path)
        .standardizedFileURL.pathComponents
    guard targetComponents.count > rootComponents.count,
          targetComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
        return nil
    }
    return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
}
```

Normalize at the start of `cliOpenDocument`, reporting the original input on failure:

```swift
func cliOpenDocument(path inputPath: String) async throws {
    guard let path = cliRelativePath(inputPath),
          await cliEnsureIndexed(path: path) else {
        throw CLIBackendError.notFound(inputPath)
    }
    if let existing = tabs.first(where: { $0.location.openPath == path }) {
        await selectTab(existing.id)
    } else {
        await openInNewTab(path)
    }
}
```

In `CLIHandlers.read`, convert `req.path` before index lookup and keep the original string in the `not_found` message:

```swift
guard let inputPath = req.path else {
    return .failure(code: CLIErrorCode.badRequest, message: "missing path")
}
guard let path = model.cliRelativePath(inputPath),
      await model.cliEnsureIndexed(path: path),
      let entry = model.cliEntry(path: path) else {
    return .failure(code: CLIErrorCode.notFound, message: "not found: \(inputPath)")
}
```

Change the `Read` and `Open` argument help strings in `main.swift` to `"Workspace-relative or absolute path of the document."`.

- [ ] **Step 4: Run focused and related tests**

Run:

```bash
cd apple
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter CLIServerTests
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter 'CLIServerTests|NavigationContextTests'
```

Expected: all selected tests pass, including the existing relative-path cases.

- [ ] **Step 5: Commit the implementation**

```bash
git add apple/Tests/MarpleKitTests/CLIServerTests.swift apple/Sources/Marple/CLI/AppModel+CLI.swift apple/Sources/Marple/CLI/CLIHandlers.swift apple/Sources/marple-cli/main.swift
git commit -m "fix(cli): accept absolute vault paths"
```

- [ ] **Step 6: Build and exercise the real CLI**

Run the full test suite, rebuild the local app with `cd apple && make build`, restart it, and verify:

```bash
marple-cli read '/Users/ramudai/Documents/Learn/bts/vault/authors/clare-carlisle.md'
marple-cli open '/Users/ramudai/Documents/Learn/bts/vault/authors/clare-carlisle.md'
marple-cli read '/tmp/marple-cli-outside.md'
```

Expected: the two vault-internal commands return success with the canonical relative path; the outside path returns `not_found`.
