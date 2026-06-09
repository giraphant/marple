# Marple iOS Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only iPhone reader over the same iCloud-Drive-synced vault — 6-type sidebar → entry list → markdown reader, plus full-text search and an Inspector panel.

**Architecture:** Reuse `MarpleKit` (model, indexer, `IndexDatabase`, derivations, markdown renderer) unchanged in logic, made iOS-buildable by platform-guarding 4 macOS-only files and porting `AttributedStringRenderer` to cross-platform. A new SwiftUI iOS app under `apple/ios/` picks the synced vault folder (security-scoped bookmark), re-indexes the `.md` into the app's **private** container (never the synced vault), and reads through a new `IOSVaultClient: VaultClient`. The rendered `NSAttributedString` is shown in a `UITextView`.

**Tech Stack:** Swift 6, SwiftUI, UIKit/TextKit (`UITextView`), MarpleKit (GRDB/SQLite FTS5, swift-markdown, Yams). iOS 17+. No MLX (semantic search deferred).

**Branch:** all work stays on `marple-ios-companion`.

**Spec:** `docs/superpowers/specs/2026-06-09-marple-ios-companion-design.md`

---

## Conventions

- Build/test commands run from `apple/`.
- macOS regression command (Command Line Tools, not full Xcode — see README):
  ```sh
  swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  ```
- iOS build is verified in Xcode against the new app target + iPhone simulator (SwiftPM cannot produce an iOS `.app`).
- Commit after every task. Conventional-commit messages, present tense.
- **Each shared-file change must keep the macOS app byte-for-byte behaviorally identical** — the platform guards and typealiases resolve to the existing AppKit types on macOS by construction.

---

## Phase 1 — Make MarpleKit iOS-buildable

### Task 1: Add iOS platform to the package

**Files:**
- Modify: `apple/Package.swift:6`

- [ ] **Step 1: Add `.iOS(.v17)` to platforms**

Change line 6 from:
```swift
    platforms: [.macOS(.v15)],
```
to:
```swift
    platforms: [.macOS(.v15), .iOS(.v17)],
```

Note: only the `MarpleKit` target (and its deps: swift-markdown, GRDB, Yams, swift-transformers) will be compiled for iOS, because the iOS app target (Task 6) links **only** the `MarpleKit` product. The `Marple` executable, `MarpleEmbeddings` (MLX), and the CLI targets are never built for iOS.

- [ ] **Step 2: Verify macOS still resolves and builds**

Run: `swift build`
Expected: builds successfully (the platform addition does not change macOS resolution).

- [ ] **Step 3: Commit**

```bash
git add apple/Package.swift
git commit -m "build(ios): declare iOS 17 platform for MarpleKit"
```

---

### Task 2: Platform-guard the three macOS-only files iOS never uses

`VaultWatcher` (FSEvents), `SupersetRunner` (`Process`), and `LocalVaultClient` (`NSWorkspace`/`Process`) are referenced only by the macOS `Marple` app target, not within MarpleKit's iOS-reachable code (verified: `LocalVaultClient` appears only in a doc comment in `VaultClient.swift`). Excluding them from the iOS compile is clean.

**Files:**
- Modify: `apple/Sources/MarpleKit/Vault/VaultWatcher.swift`
- Modify: `apple/Sources/MarpleKit/Vault/SupersetRunner.swift`
- Modify: `apple/Sources/MarpleKit/Vault/LocalVaultClient.swift`

- [ ] **Step 1: Wrap each file's entire body in a macOS guard**

For all three files, wrap everything below the `import` lines:

```swift
#if os(macOS)
// ... existing file contents unchanged ...
#endif
```

Place `#if os(macOS)` immediately after the existing `import` statements at the top, and `#endif` at the very end of the file. Do not alter the code inside.

- [ ] **Step 2: Verify macOS build unaffected**

Run: `swift build`
Expected: builds successfully (on macOS the guard is always true).

- [ ] **Step 3: Commit**

```bash
git add apple/Sources/MarpleKit/Vault/VaultWatcher.swift apple/Sources/MarpleKit/Vault/SupersetRunner.swift apple/Sources/MarpleKit/Vault/LocalVaultClient.swift
git commit -m "build(ios): exclude FSEvents/Process/NSWorkspace files from iOS build"
```

---

### Task 3: Give `GitDates` an iOS fallback (mtime-based added dates)

`GitDates` spawns `git` via `Process`, which does not exist on iOS. On iOS, derive each `vault/**.md` file's "added date" from its filesystem modification date (approximate, acceptable for a reader — and the app never shows relative dates anyway).

**Files:**
- Modify: `apple/Sources/MarpleKit/Indexer/GitDates.swift`

- [ ] **Step 1: Guard the macOS git path and add the iOS branch**

Wrap the existing `runGitCapture`, `gitAddedDates`, and `gitAddedDate` implementations in `#if os(macOS)`. Then add an `#else` iOS branch that walks `vault/` for `.md` modification dates. The file already has `parseRFC3339` (keep it outside the guard — it's pure). Structure:

```swift
import Foundation

// parseRFC3339 stays here, unguarded (pure, used only by the macOS branch but harmless).

#if os(macOS)
private func runGitCapture(_ args: [String], workspaceRoot: String) -> String? { /* unchanged */ }
public func gitAddedDates(workspaceRoot: String) -> [String: Int64] { /* unchanged */ }
public func gitAddedDate(workspaceRoot: String, relPath: String) -> Int64 { /* unchanged */ }
#else
/// iOS: no git. Approximate each vault file's "added date" with its filesystem
/// modification date (epoch-ms). Key is the workspace-relative path (e.g.
/// "vault/foo/bar.md"), matching the macOS git map's key shape.
public func gitAddedDates(workspaceRoot: String) -> [String: Int64] {
    var map = [String: Int64]()
    let vaultURL = URL(fileURLWithPath: workspaceRoot).appendingPathComponent("vault")
    let fm = FileManager.default
    guard let en = fm.enumerator(at: vaultURL,
                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                 options: [.skipsHiddenFiles]) else { return map }
    for case let url as URL in en where url.pathExtension == "md" {
        let rel = url.path.hasPrefix(workspaceRoot + "/")
            ? String(url.path.dropFirst(workspaceRoot.count + 1))
            : url.lastPathComponent
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            map[rel] = Int64(date.timeIntervalSince1970 * 1000)
        }
    }
    return map
}

public func gitAddedDate(workspaceRoot: String, relPath: String) -> Int64 {
    let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(relPath)
    if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
        return Int64(date.timeIntervalSince1970 * 1000)
    }
    return 0
}
#endif
```

- [ ] **Step 2: Verify macOS build + existing indexer tests pass**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: PASS (macOS branch is unchanged; tests untouched).

- [ ] **Step 3: Commit**

```bash
git add apple/Sources/MarpleKit/Indexer/GitDates.swift
git commit -m "build(ios): mtime-based added-date fallback when git is unavailable"
```

---

### Task 4: Make `VaultIndexer` write its index to a configurable path

The indexer hardcodes `<workspaceRoot>/.marple/index.sqlite` and creates `<workspaceRoot>/.marple/`. iOS must read `vault/` from the (read-only, synced) workspace but write the index into the app's private container. Add an optional `indexDBPath` init parameter that defaults to today's path, so the Mac is unchanged.

**Files:**
- Modify: `apple/Sources/MarpleKit/Indexer/VaultIndexer.swift` (init ~26-30, `buildFull` dir/cache lines ~84 and ~137)
- Test: `apple/Tests/MarpleKitTests/VaultIndexerDBPathTests.swift` (create)

- [ ] **Step 1: Write the failing test (runs on macOS)**

Create `apple/Tests/MarpleKitTests/VaultIndexerDBPathTests.swift`:

```swift
import Testing
import Foundation
@testable import MarpleKit

@Suite struct VaultIndexerDBPathTests {
    @Test func indexerWritesToOverridePathNotWorkspace() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("marple-idx-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        try "---\ntype: note\ntitle: Hi\n---\nbody".write(
            to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let outDB = root.appendingPathComponent("container/index.sqlite")
        let indexer = VaultIndexer(workspaceRoot: root.path, indexDBPath: outDB.path)
        _ = try indexer.buildFull()

        #expect(fm.fileExists(atPath: outDB.path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".marple/index.sqlite").path))
        try? fm.removeItem(at: root)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails to compile**

Run: `swift test --filter VaultIndexerDBPathTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: FAIL — `init(workspaceRoot:indexDBPath:)` does not exist.

- [ ] **Step 3: Add the optional parameter and route the DB dir through it**

In `VaultIndexer.swift`, change the init (around line 26):

```swift
    public init(workspaceRoot: String, indexDBPath: String? = nil) {
        self.workspaceRoot = workspaceRoot
        self.indexDBPath  = indexDBPath ?? (workspaceRoot + "/.marple/index.sqlite")
        self.vaultPath    = workspaceRoot + "/vault"
        self.sourcesPath  = workspaceRoot + "/sources"
        // ... keep any remaining existing init body ...
    }
```

Add a computed helper near the stored properties:

```swift
    /// Directory containing the index DB — the parent of `indexDBPath`. On macOS
    /// this is `<workspaceRoot>/.marple`; on iOS it is the app's private container.
    private var indexDBDir: String { (indexDBPath as NSString).deletingLastPathComponent }
```

In `buildFull()`, replace the hardcoded `.marple` directory creation (around line 84):

```swift
        // 3. Ensure the index DB directory exists.
        let marpleDir = indexDBDir
        try FileManager.default.createDirectory(
            atPath: marpleDir, withIntermediateDirectories: true)
```

And the entries-cache cleanup (around line 137):

```swift
        let cachePath = indexDBDir + "/entries.cache"
        try? FileManager.default.removeItem(atPath: cachePath)
```

(Leave every other use of `indexDBPath` as-is — they already point at the configurable path.)

- [ ] **Step 4: Run the test, verify it passes**

Run: `swift test --filter VaultIndexerDBPathTests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: PASS.

- [ ] **Step 5: Run the full suite (regression — default path unchanged)**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apple/Sources/MarpleKit/Indexer/VaultIndexer.swift apple/Tests/MarpleKitTests/VaultIndexerDBPathTests.swift
git commit -m "feat(indexer): optional indexDBPath override (iOS writes index outside the vault)"
```

---

### Task 5: Port `AttributedStringRenderer` to cross-platform

The renderer must compile and run on iOS, producing the same `NSAttributedString`. macOS keeps using AppKit types via typealiases that resolve to the existing classes.

**Files:**
- Create: `apple/Sources/MarpleKit/Markdown/Platform.swift`
- Modify: `apple/Sources/MarpleKit/Markdown/AttributedStringRenderer.swift`

- [ ] **Step 1: Create the platform typealias shim**

Create `apple/Sources/MarpleKit/Markdown/Platform.swift`:

```swift
import Foundation

#if canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformBezierPath = NSBezierPath
public typealias PlatformView = NSView
public typealias PlatformFontDescriptor = NSFontDescriptor
#elseif canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformBezierPath = UIBezierPath
public typealias PlatformView = UIView
public typealias PlatformFontDescriptor = UIFontDescriptor
#endif
```

- [ ] **Step 2: Replace AppKit type names in `AttributedStringRenderer.swift`**

Change the import (line 1-2) from:
```swift
import Foundation
import AppKit
```
to:
```swift
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
```

Then replace every `NSFont` → `PlatformFont`, `NSColor` → `PlatformColor`, `NSBezierPath` → `PlatformBezierPath` throughout the file. `NSAttributedString`, `NSMutableAttributedString`, `NSParagraphStyle`, `NSMutableParagraphStyle`, `NSRange`, `NSTextTable`, `NSTextTableBlock`, `NSTextTab`, `NSRectEdge`, `NSFontDescriptor` (use `PlatformFontDescriptor` for the `.symbolicTraits` calls), `NSUnderlineStyle`, `NSAttributedString.Key`, `NSTextAlignment` all exist on both platforms — leave them.

- [ ] **Step 3: Bridge the diverging font/color APIs**

These calls differ between AppKit and UIKit. Add a small extension block at the bottom of `Platform.swift` to normalize them, then use the normalized names in the renderer:

```swift
#if canImport(UIKit)
import UIKit

extension UIFont {
    /// AppKit parity: monospaced digits descriptor toggle is the same featureSettings API.
    static func monospacedSystemFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// Dynamic semantic colors — UIKit equivalents of the AppKit names the renderer uses.
extension UIColor {
    static var textColor: UIColor { .label }
    static var linkColor: UIColor { .link }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var separatorColor: UIColor { .separator }
}
#endif
```

For `NSFontManager` (used in `RenderStyle.font(_:weight:)` and `synthStroke` and `managerWeight`): UIKit has no `NSFontManager`. Wrap those bodies per-platform. In `AttributedStringRenderer.swift`, change `func font(_:weight:)` to:

```swift
    func font(_ size: Double, weight: PlatformFont.Weight) -> PlatformFont {
        if let fontFamily {
            #if canImport(AppKit)
            if let f = NSFontManager.shared.font(
                withFamily: fontFamily, traits: [], weight: Self.managerWeight(weight), size: size) {
                return f
            }
            if let f = NSFont(name: fontFamily, size: size) { return f }
            #elseif canImport(UIKit)
            // UIKit: resolve by family + weight trait via descriptor; fall back to name.
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let desc = base.fontDescriptor.withFamily(fontFamily)
                .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
            let resolved = UIFont(descriptor: desc, size: size)
            if resolved.familyName == fontFamily { return resolved }
            if let f = UIFont(name: fontFamily, size: size) { return f }
            #endif
        }
        return PlatformFont.systemFont(ofSize: size, weight: weight)
    }
```

Wrap `synthStroke(of:target:)`'s `NSFontManager.shared.weight(of:)` call in `#if canImport(AppKit)`; in the `#else` branch return `nil` (no synthetic-bold on iOS in v1 — fonts are system-resolved, so the deficit is zero anyway):

```swift
    func synthStroke(of resolved: PlatformFont, target: PlatformFont.Weight) -> CGFloat? {
        guard fontFamily != nil else { return nil }
        #if canImport(AppKit)
        let deficit = Self.managerWeight(target) - NSFontManager.shared.weight(of: resolved)
        guard deficit > 0 else { return nil }
        return -CGFloat(deficit) * 1.1
        #else
        return nil
        #endif
    }
```

`withMonospacedDigits` uses `font.fontDescriptor.addingAttributes([.featureSettings: ...])` with `kNumberSpacingType`/`kMonospacedNumbersSelector` (CoreText constants, available on both via `import CoreText`). Add `import CoreText` to the renderer's import block (it was already imported on line 3 — keep it). `PlatformFont(descriptor:size:)` exists on both.

- [ ] **Step 4: Port the two `drawBackground` table-chrome methods**

`RoundedCardBlock.drawBackground` and `TableCellBlock.drawBackground` override `NSTextTableBlock`. The override signature's view parameter type differs (`NSView` vs `UIView`), and the drawing uses `NSBezierPath`/`NSGraphicsContext` (macOS) vs `UIBezierPath`/`UIGraphicsGetCurrentContext` (iOS).

For `RoundedCardBlock` (lines ~42-52), replace with:

```swift
    override func drawBackground(withFrame frameRect: CGRect, in controlView: PlatformView,
                                 characterRange: NSRange, layoutManager: NSLayoutManager) {
        lastFrame = frameRect
        let rect = frameRect.insetBy(dx: 0.5, dy: 0.5)
        #if canImport(AppKit)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill(); path.fill()
        path.lineWidth = 1; borderColor.setStroke(); path.stroke()
        #elseif canImport(UIKit)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
        fillColor.setFill(); path.fill()
        path.lineWidth = 1; borderColor.setStroke(); path.stroke()
        #endif
    }
```

`interiorClipPath()` returns a `PlatformBezierPath`; change its body's `NSBezierPath(roundedRect:xRadius:yRadius:)` to the same `#if` shape (macOS `NSBezierPath(roundedRect:xRadius:yRadius:)`, iOS `UIBezierPath(roundedRect:cornerRadius:)`) and change the return type to `PlatformBezierPath`.

For `TableCellBlock.drawBackground` (lines ~74-106), the body uses `NSGraphicsContext.current?.saveGraphicsState()` / `restoreGraphicsState()`, `setClip()`, `band.fill()`, and an `NSBezierPath` hairline. Replace with a per-platform body that shares the geometry:

```swift
    override func drawBackground(withFrame frameRect: CGRect, in controlView: PlatformView,
                                 characterRange: NSRange, layoutManager: NSLayoutManager) {
        lastFrame = frameRect
        let cardFrame = card?.lastFrame ?? .zero
        let hasCard = cardFrame != .zero

        #if canImport(AppKit)
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        if hasCard { card?.interiorClipPath().setClip() }
        #elseif canImport(UIKit)
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        defer { ctx?.restoreGState() }
        if hasCard { card?.interiorClipPath().addClip() }
        #endif

        if let fill = headerFillColor {
            let left = (hasCard && roundTopLeft) ? cardFrame.minX : frameRect.minX
            let right = (hasCard && roundTopRight) ? cardFrame.maxX : frameRect.maxX
            let top = hasCard ? cardFrame.minY : frameRect.minY
            let band = CGRect(x: left, y: top, width: right - left, height: frameRect.maxY - top)
            fill.setFill()
            #if canImport(AppKit)
            band.fill()
            #elseif canImport(UIKit)
            UIBezierPath(rect: band).fill()
            #endif
        }
        if let separator = rowSeparatorColor {
            let y = frameRect.maxY - 0.5
            let line = PlatformBezierPath()
            #if canImport(AppKit)
            line.move(to: NSPoint(x: frameRect.minX, y: y)); line.line(to: NSPoint(x: frameRect.maxX, y: y))
            #elseif canImport(UIKit)
            line.move(to: CGPoint(x: frameRect.minX, y: y)); line.addLine(to: CGPoint(x: frameRect.maxX, y: y))
            #endif
            line.lineWidth = 1; separator.setStroke(); line.stroke()
        }
    }
```

Note: `NSRect`/`NSPoint` are typealiases of `CGRect`/`CGPoint`, so changing the signature to `CGRect`/`CGPoint` is identical on macOS. The other internal helpers (`tableColumnWidthPercentages`, `singleLineWidth`, etc.) use `(text as NSString).size(withAttributes:)` — available on both — and `PlatformFont`; no further changes.

- [ ] **Step 5: Verify macOS build + full suite (renderer behavior unchanged)**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: PASS — on macOS every typealias/`#if` resolves to the original AppKit code.

- [ ] **Step 6: Commit**

```bash
git add apple/Sources/MarpleKit/Markdown/Platform.swift apple/Sources/MarpleKit/Markdown/AttributedStringRenderer.swift
git commit -m "feat(markdown): cross-platform renderer (AppKit/UIKit) for iOS reuse"
```

---

## Phase 2 — iOS app scaffold + file access

### Task 6: Create the iOS app Xcode project

**Files:**
- Create: `apple/ios/MarpleiOS.xcodeproj` (Xcode project)
- Create: `apple/ios/MarpleiOS/MarpleiOSApp.swift`
- Create: `apple/ios/MarpleiOS/Info.plist` entries (see below)

- [ ] **Step 1: Create the project in Xcode**

In Xcode: File → New → Project → iOS → App.
- Product Name: `MarpleiOS`
- Interface: SwiftUI, Language: Swift, Minimum Deployments: iOS 17.
- Save into `apple/ios/`.

Then File → Add Package Dependencies → Add Local… → select `apple/` (the SwiftPM package) → add the **`MarpleKit`** library product to the `MarpleiOS` target (do NOT add `MarpleEmbeddings`).

- [ ] **Step 2: Enable iCloud Documents capability + Info.plist keys**

In the target's Signing & Capabilities, add **iCloud → iCloud Documents**. In `Info.plist` add:
- `NSUbiquitousContainers` is not required for read access to an arbitrary picked folder, but to let the user browse iCloud Drive in the picker, set `LSSupportsOpeningDocumentsInPlace` = `YES` and `UISupportsDocumentBrowser` = `NO`.

- [ ] **Step 3: Minimal app entry that builds and runs**

Replace `MarpleiOSApp.swift` with:

```swift
import SwiftUI

@main
struct MarpleiOSApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Marple")
        }
    }
}
```

- [ ] **Step 4: Verify it builds and launches on the simulator**

In Xcode select an iPhone simulator and Run (⌘R).
Expected: a blank screen showing "Marple". This confirms MarpleKit compiles and links for iOS.

- [ ] **Step 5: Commit**

```bash
git add apple/ios
git commit -m "feat(ios): scaffold MarpleiOS app target linking MarpleKit"
```

---

### Task 7: `VaultBookmark` — pick + persist the synced folder

**Files:**
- Create: `apple/ios/MarpleiOS/Vault/VaultBookmark.swift`

- [ ] **Step 1: Implement bookmark storage + resolution**

```swift
import Foundation

/// Persists the user's pick of the iCloud-Drive-synced vault folder as a
/// security-scoped bookmark, and resolves it on launch. iOS analogue of the Mac
/// workspace picker. The caller owns balancing start/stop access.
enum VaultBookmark {
    private static let key = "marple.ios.vaultBookmark"

    /// Save a freshly picked folder URL as a security-scoped bookmark.
    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: [],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Resolve the persisted bookmark to a URL. Returns nil if none saved.
    /// `isStale` true means re-save (caller should re-pick if resolution fails).
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return url
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
```

- [ ] **Step 2: Build the app target**

Run in Xcode (⌘B).
Expected: builds. (UI wiring of the picker comes in Task 10.)

- [ ] **Step 3: Commit**

```bash
git add apple/ios/MarpleiOS/Vault/VaultBookmark.swift
git commit -m "feat(ios): security-scoped bookmark for the synced vault folder"
```

---

### Task 8: `ICloudMaterializer` — ensure a file is downloaded before reading

**Files:**
- Create: `apple/ios/MarpleiOS/Vault/ICloudMaterializer.swift`

- [ ] **Step 1: Implement on-demand download + wait**

```swift
import Foundation

/// Ensures an iCloud-Drive file is materialized (downloaded) before we read it.
/// iCloud evicts unused files to 0-byte placeholders; reading one needs an
/// explicit download. Only used for `.md` (and, in v2, media).
enum ICloudMaterializer {
    enum MaterializeError: Error { case timedOut(URL) }

    /// Download `url` if it is an evicted placeholder, polling until current.
    /// No-op if already downloaded or not an iCloud item. Throws on timeout.
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 20) async throws {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        func status() -> URLUbiquitousItemDownloadingStatus? {
            (try? url.resourceValues(forKeys: keys))?.ubiquitousItemDownloadingStatus
        }
        // Not an iCloud item, or already current → nothing to do.
        if status() == .current || status() == nil { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status() == .current { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw MaterializeError.timedOut(url)
    }
}
```

- [ ] **Step 2: Build the app target**

Run in Xcode (⌘B).
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add apple/ios/MarpleiOS/Vault/ICloudMaterializer.swift
git commit -m "feat(ios): on-demand iCloud Drive materialization for vault files"
```

---

### Task 9: `IOSVaultClient` — read-only `VaultClient` over the on-device index

**Files:**
- Create: `apple/ios/MarpleiOS/Vault/IOSVaultClient.swift`
- Test: add an iOS unit-test target `MarpleiOSTests` with `IOSVaultClientTests.swift`

The read path (index query + file read) is the only logic; all write/open methods are unsupported in a read-only companion.

- [ ] **Step 1: Implement the client**

```swift
import Foundation
import MarpleKit

/// Read-only `VaultClient` for iOS. Reads entries/search from the on-device
/// `IndexDatabase` (built into the app container) and entry text from the
/// synced vault files (materializing them from iCloud first). Write/open
/// operations are unsupported in v1.
struct IOSVaultClient: VaultClient {
    let workspaceRoot: String
    let db: IndexDatabase   // named `db`, not `index`, to avoid colliding with index()

    func index() async throws -> [Entry] { try db.loadEntries() }

    func search(_ query: SearchQuery) async throws -> [SearchHit] {
        try db.search(query.q, type: query.type, minRating: query.minRating,
                      theme: query.theme, limit: query.limit)
    }

    func entryText(path: String) async throws -> String {
        let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(path)
        try await ICloudMaterializer.ensureDownloaded(url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func fileURL(for path: String) -> URL? {
        URL(fileURLWithPath: workspaceRoot).appendingPathComponent(path)
    }

    // MARK: Unsupported in the read-only companion (UI never calls these in v1).
    func openInEditor(path: String, app: String) async throws {}
    func openPDF(slug: String) async throws { throw VaultError.notFound("read-only") }
    func openTranslation(slug: String) async throws { throw VaultError.notFound("read-only") }
    func hasTranslation(slug: String) -> Bool { false }
    func imageOriginalURL(forImageEntryPath path: String) async throws -> URL? { nil }
    func createImageObject(from sourceURL: URL, title: String?) async throws -> Entry {
        throw VaultError.notFound("read-only")
    }
    func writeFile(path: String, text: String) async throws { throw VaultError.notFound("read-only") }
    func createNote(path: String, text: String) async throws { throw VaultError.notFound("read-only") }
    func moveToTrash(path: String) async throws -> String { throw VaultError.notFound("read-only") }
    func listTrash() async throws -> [TrashItem] { [] }
    func restoreTrash(name: String) async throws -> String { throw VaultError.notFound("read-only") }
    func purgeTrash(name: String) async throws { throw VaultError.notFound("read-only") }
}
```


- [ ] **Step 2: Add an iOS test target and a failing test**

In Xcode: File → New → Target → iOS Unit Testing Bundle named `MarpleiOSTests`. Add `MarpleKit` to its dependencies. Create `IOSVaultClientTests.swift`:

```swift
import XCTest
import MarpleKit
@testable import MarpleiOS

final class IOSVaultClientTests: XCTestCase {
    func testIndexAndEntryTextOverFixtureVault() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ios-vc-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        let md = "---\ntype: note\ntitle: Hello\n---\nthe body text"
        try md.write(to: vault.appendingPathComponent("hello.md"), atomically: true, encoding: .utf8)

        let dbPath = root.appendingPathComponent("container/index.sqlite").path
        let indexer = VaultIndexer(workspaceRoot: root.path, indexDBPath: dbPath)
        _ = try indexer.buildFull()

        let client = IOSVaultClient(workspaceRoot: root.path, db: IndexDatabase(indexDBPath: dbPath))
        let entries = try await client.index()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "Hello")

        let text = try await client.entryText(path: "vault/hello.md")
        XCTAssertTrue(text.contains("the body text"))
        try? fm.removeItem(at: root)
    }
}
```

- [ ] **Step 3: Run the iOS test target, verify it passes**

In Xcode: ⌘U with an iPhone simulator selected (or `xcodebuild test -scheme MarpleiOS -destination 'platform=iOS Simulator,name=iPhone 15'` from `apple/ios/`).
Expected: PASS. (Plain files are not iCloud items, so `ensureDownloaded` is a no-op.)

- [ ] **Step 4: Commit**

```bash
git add apple/ios
git commit -m "feat(ios): read-only IOSVaultClient over on-device index + tests"
```

---

## Phase 3 — Boot, index, and the reader model

### Task 10: `ReaderModel` + boot assembly (pick → materialize → reconcile → load)

**Files:**
- Create: `apple/ios/MarpleiOS/App/ReaderModel.swift`
- Create: `apple/ios/MarpleiOS/App/SetupView.swift`
- Modify: `apple/ios/MarpleiOS/MarpleiOSApp.swift`

- [ ] **Step 1: Implement `ReaderModel`**

```swift
import Foundation
import SwiftUI
import MarpleKit

@MainActor
@Observable
final class ReaderModel {
    enum Phase { case needsFolder, indexing, ready, failed(String) }

    private(set) var phase: Phase = .needsFolder
    private(set) var entries: [Entry] = []
    private var client: IOSVaultClient?
    private var workspaceRoot: String?

    /// App container path for the private index DB (never the synced vault).
    private var containerDBPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarpleIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.sqlite").path
    }

    /// Resolve a saved folder bookmark and boot; otherwise wait for a pick.
    func boot() async {
        guard let url = VaultBookmark.resolve() else { phase = .needsFolder; return }
        await start(folder: url)
    }

    /// Called by the picker with a freshly chosen folder.
    func didPickFolder(_ url: URL) async {
        try? VaultBookmark.save(url)
        await start(folder: url)
    }

    private func start(folder url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            phase = .failed("无法访问所选文件夹"); return
        }
        let root = url.path
        workspaceRoot = root
        phase = .indexing
        let dbPath = containerDBPath
        do {
            try await materializeMarkdown(under: root)
            try await Task.detached(priority: .utility) {
                let indexer = VaultIndexer(workspaceRoot: root, indexDBPath: dbPath)
                if indexer.canSkipFullBuild() { _ = try indexer.reconcile() }
                else { _ = try indexer.buildFull() }
            }.value
            let db = IndexDatabase(indexDBPath: dbPath)
            let c = IOSVaultClient(workspaceRoot: root, db: db)
            self.client = c
            self.entries = try await c.index()
            phase = .ready
        } catch {
            phase = .failed("建立索引失败:\(error.localizedDescription)")
        }
    }

    /// Re-index on foreground (cheap incremental reconcile).
    func refresh() async {
        guard let root = workspaceRoot, case .ready = phase else { return }
        let dbPath = containerDBPath
        do {
            try await materializeMarkdown(under: root)
            try await Task.detached(priority: .utility) {
                _ = try VaultIndexer(workspaceRoot: root, indexDBPath: dbPath).reconcile()
            }.value
            if let c = client { self.entries = try await c.index() }
        } catch { /* keep last good entries */ }
    }

    func text(for entry: Entry) async -> String {
        (try? await client?.entryText(path: entry.path)) ?? ""
    }

    func search(_ q: String) async -> [SearchHit] {
        (try? await client?.search(SearchQuery(q: q, limit: 80))) ?? []
    }

    /// Force-download only `.md` files (skip heavy media/PDFs).
    private func materializeMarkdown(under root: String) async throws {
        let vault = URL(fileURLWithPath: root).appendingPathComponent("vault")
        let fm = FileManager.default
        guard let en = fm.enumerator(at: vault, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en where url.pathExtension == "md" {
            try? await ICloudMaterializer.ensureDownloaded(url)
        }
    }
}
```

- [ ] **Step 2: Implement `SetupView` (folder picker)**

```swift
import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    let onPick: (URL) -> Void
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("选择已同步的文库文件夹").font(.headline)
            Text("通过 iCloud Drive 同步过来的 Marple 文库根目录").font(.subheadline).foregroundStyle(.secondary)
            Button("选择文件夹…") { showPicker = true }.buttonStyle(.borderedProminent)
        }
        .padding()
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { onPick(url) }
        }
    }
}
```

- [ ] **Step 3: Wire the app entry to the model + lifecycle**

Replace `MarpleiOSApp.swift`:

```swift
import SwiftUI

@main
struct MarpleiOSApp: App {
    @State private var model = ReaderModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.boot() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.refresh() } }
                }
        }
    }
}
```

(RootView is defined in Task 11; create a temporary stub now if needed to build:
`struct RootView: View { let model: ReaderModel; var body: some View { Text("boot") } }`)

- [ ] **Step 4: Build the app target**

Run in Xcode (⌘B).
Expected: builds.

- [ ] **Step 5: Commit**

```bash
git add apple/ios
git commit -m "feat(ios): ReaderModel boot/index/refresh + folder setup"
```

---

## Phase 4 — UI shell

### Task 11: `RootView` + `SidebarScreen` (type list)

**Files:**
- Create: `apple/ios/MarpleiOS/UI/RootView.swift`
- Create: `apple/ios/MarpleiOS/UI/SidebarScreen.swift`

- [ ] **Step 1: Implement `RootView` (phase router + NavigationStack)**

```swift
import SwiftUI

struct RootView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        switch model.phase {
        case .needsFolder:
            SetupView { url in Task { await model.didPickFolder(url) } }
        case .indexing:
            VStack(spacing: 12) { ProgressView(); Text("正在建立索引…").foregroundStyle(.secondary) }
        case .failed(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg).multilineTextAlignment(.center).padding()
                Button("重新选择文件夹") { Task { VaultBookmark.clear(); await model.boot() } }
            }
        case .ready:
            NavigationStack { SidebarScreen(model: model) }
        }
    }
}
```

- [ ] **Step 2: Implement `SidebarScreen` (canonical type order)**

```swift
import SwiftUI
import MarpleKit

struct SidebarScreen: View {
    @Bindable var model: ReaderModel

    var body: some View {
        List(EntryType.modeled, id: \.rawValue) { type in
            NavigationLink {
                EntryListScreen(model: model, type: type)
            } label: {
                Label(type.label, systemImage: symbol(for: type))
                    .badge(model.entries.filter { $0.type == type }.count)
            }
        }
        .navigationTitle("文库")
    }

    private func symbol(for type: EntryType) -> String {
        switch type {
        case .paper: "doc.text"; case .book: "book"; case .author: "person"
        case .topic: "tag"; case .journal: "newspaper"; case .chapter: "doc.plaintext"
        case .note: "note.text"; case .image: "photo"; case .talk: "mic"
        default: "doc"
        }
    }
}
```

(Uses the destination-closure `NavigationLink`, so no `Hashable` conformance is needed on `EntryType` or `Entry` — `Entry` is only `Equatable`, not `Hashable`.)

- [ ] **Step 3: Build + run on simulator**

Expected: after picking a folder and indexing, a "文库" list of types with counts appears. Tapping a type pushes a (next task) list.

- [ ] **Step 4: Commit**

```bash
git add apple/ios
git commit -m "feat(ios): root phase router + type sidebar"
```

---

### Task 12: `EntryListScreen` + full-text search

**Files:**
- Create: `apple/ios/MarpleiOS/UI/EntryListScreen.swift`

- [ ] **Step 1: Implement the list with `.searchable`**

```swift
import SwiftUI
import MarpleKit

struct EntryListScreen: View {
    @Bindable var model: ReaderModel
    let type: EntryType
    @State private var query = ""
    @State private var hits: [Entry] = []

    private var typeEntries: [Entry] {
        model.entries.filter { $0.type == type }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }
    private var shown: [Entry] { query.isEmpty ? typeEntries : hits }

    var body: some View {
        List(shown) { entry in
            NavigationLink {
                DocScreen(model: model, entry: entry)
            } label: {
                EntryRow(entry: entry)
            }
        }
        .navigationTitle(type.label)
        .searchable(text: $query, prompt: "全文搜索")
        .task(id: query) {
            guard !query.isEmpty else { hits = []; return }
            let results = await model.search(query)
            hits = results.map(\.entry).filter { $0.type == type }
        }
    }
}

private struct EntryRow: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title ?? (entry.path as NSString).lastPathComponent)
                .font(.body).lineLimit(2)
            if !entry.author.isEmpty {
                Text(entry.author.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
```

Note: search is global (FTS over the whole index); we filter hits to the current `type` so the screen stays scoped. (A global search entry point can come in v2.) `Entry` is `Identifiable` (`id == path`) so `List` needs no extra `id:`. Navigation uses the destination-closure form, so `Entry` need not be `Hashable`.

- [ ] **Step 2: Build + run on simulator**

Expected: tapping a type shows its entries; typing in the search bar filters by full-text matches within that type.

- [ ] **Step 3: Commit**

```bash
git add apple/ios
git commit -m "feat(ios): entry list with full-text search"
```

---

### Task 13: `DocScreen` — `UITextView` markdown reader + Inspector

**Files:**
- Create: `apple/ios/MarpleiOS/UI/MarkdownTextView.swift`
- Create: `apple/ios/MarpleiOS/UI/DocScreen.swift`

- [ ] **Step 1: Implement the `UIViewRepresentable` over `UITextView`**

```swift
import SwiftUI
import UIKit
import MarpleKit

/// Displays a rendered markdown `NSAttributedString` in a read-only UITextView,
/// mirroring the Mac's NSTextView-based MarkdownTextView.
struct MarkdownTextView: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        tv.alwaysBounceVertical = true
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.attributedText = attributed
    }
}
```

- [ ] **Step 2: Implement `DocScreen` (render pipeline + Inspector sheet)**

```swift
import SwiftUI
import MarpleKit

struct DocScreen: View {
    @Bindable var model: ReaderModel
    let entry: Entry
    @State private var body_ = ""
    @State private var rendered = NSAttributedString()
    @State private var stats: DocStats?
    @State private var outline: [OutlineItem] = []
    @State private var showInspector = false

    private var style: RenderStyle {
        RenderStyle(size: 18, fontFamily: nil, bodyWeight: .regular,
                    letterSpacing: 0, lineHeight: 1.6)
    }

    var body: some View {
        MarkdownTextView(attributed: rendered)
            .navigationTitle(entry.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { showInspector = true } label: { Image(systemName: "info.circle") }
            }
            .sheet(isPresented: $showInspector) {
                InspectorSheet(entry: entry, stats: stats, outline: outline)
            }
            .task(id: entry.id) { await load() }
    }

    private func load() async {
        let raw = await model.text(for: entry)
        body_ = raw
        let md = Wikilink.preprocessForRendering(raw)
        let doc = MarkdownRenderer.render(md, style: style)
        rendered = doc.attributedString
        outline = MarpleKit.outline(from: doc.headings)
        stats = computeDocStats(raw)
    }
}

private struct InspectorSheet: View {
    let entry: Entry
    let stats: DocStats?
    let outline: [OutlineItem]

    var body: some View {
        NavigationStack {
            List {
                if let s = stats {
                    Section("统计") {
                        LabeledContent("字数", value: "\(s.chars)")
                        LabeledContent("词数", value: "\(s.words)")
                        LabeledContent("段落", value: "\(s.paragraphs)")
                        LabeledContent("阅读", value: "\(s.minutes) 分钟")
                    }
                }
                Section("信息") {
                    LabeledContent("类型", value: entry.type.label)
                    if !entry.author.isEmpty { LabeledContent("作者", value: entry.author.joined(separator: ", ")) }
                    if let y = entry.year { LabeledContent("年份", value: y) }
                    if !entry.themes.isEmpty { LabeledContent("主题", value: entry.themes.joined(separator: " · ")) }
                }
                if !outline.isEmpty {
                    Section("目录") {
                        ForEach(outline) { item in
                            Text(item.text)
                                .font(.callout)
                                .padding(.leading, CGFloat((item.level - 1) * 12))
                        }
                    }
                }
            }
            .navigationTitle("信息")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
```

Note: `outline(from:)` is a free function in MarpleKit — call it as `MarpleKit.outline(from:)` to avoid any local shadowing. `EntryType.label` provides the Chinese labels.

- [ ] **Step 3: Build + run on simulator**

Expected: tapping an entry opens the markdown reader with the same typographic treatment as the Mac (headings, tables with rounded cards, CJK spacing). The info button opens the Inspector sheet with stats / metadata / outline.

- [ ] **Step 4: Commit**

```bash
git add apple/ios
git commit -m "feat(ios): UITextView markdown reader + inspector sheet"
```

---

## Phase 5 — Device verification (GUI)

These require a real iPhone signed in to the same iCloud account, with the vault already synced via iCloud Drive. Run on device from Xcode.

- [ ] **V1 — Folder pick:** Launch, choose the synced vault folder in the picker. Expect: indexing spinner, then the 文库 type list with non-zero counts.
- [ ] **V2 — Read a downloaded doc:** Open a paper/note whose `.md` is already local. Expect: rendered reader, tables show rounded cards, CJK spacing matches the Mac.
- [ ] **V3 — Read an evicted doc:** In the Files app, evict a vault `.md` ("Remove Download"), relaunch Marple, open that entry. Expect: it materializes and renders (no crash, brief wait).
- [ ] **V4 — Search:** In a type list, search a CJK term known to appear in bodies. Expect: full-text matches within that type.
- [ ] **V5 — Inspector:** Open the info sheet on a doc with headings. Expect: stats, metadata, and a heading outline.
- [ ] **V6 — Foreground refresh:** On the Mac, add/edit a vault `.md`; let it sync; foreground the iPhone app. Expect: the new/edited entry appears after the incremental reconcile.

If any verification fails, use superpowers:systematic-debugging before patching.

---

## Self-Review notes (author)

- **Spec coverage:** §3 build → Tasks 1, 6. §4 Workstream A → Tasks 2,3,5. Indexer-path seam (§5 boot, "never write synced vault") → Task 4. Workstream B → Tasks 7,8,9. Workstream C → Task 10. Workstream D → Tasks 11,12,13. §6 error handling → RootView `.failed`, ICloudMaterializer timeout, `refresh()` keep-last-good. §7 testing → Tasks 4,9 (unit) + Phase 5 (GUI).
- **Deferred (file in Linear if they survive):** v2 card/grid, PDF/translation viewing, semantic search, writes; global (cross-type) search entry point; reading-font settings (v1 hardcodes a sensible `RenderStyle`).
