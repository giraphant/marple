# Local Image Objects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not create git commits unless the user explicitly asks; this repository currently has unrelated uncommitted work.

**Goal:** Add a file-first local image object MVP where each image is a directory under `vault/images/<semantic-slug>/` containing `image.md` metadata and `original.<ext>` image data, with image entries browseable as a Marple type.

**Architecture:** Keep the vault as source of truth and `.marple/index.sqlite` as a derived cache. Images are ordinary indexed Markdown entries (`type: image`) whose object directory is the parent of `image.md`; the image binary is found by convention as `original.<supported-ext>` in that directory. No MinIO, catalog, hash path, or remote sync in this MVP.

**Tech Stack:** Swift 6, SwiftPM, swift-testing, GRDB, SwiftUI, AppKit `NSImage`/`NSTextAttachment`.

---

## File Structure

- Modify `apple/Sources/MarpleKit/Model/Entry.swift`
  - Add modeled entry type `.image` with label `图片` and include it in sidebar order.
- Create `apple/Sources/MarpleKit/Model/ImageAsset.swift`
  - Pure helper for resolving `original.<ext>` next to an image entry path.
- Modify `apple/Sources/MarpleKit/Indexer/IndexedEntry.swift`
  - Let `type: image` index as a normal entry; title comes from frontmatter `title`/`name`, author/source/themes are already supported.
- Modify `apple/Sources/MarpleKit/Indexer/IndexWriter.swift`
  - No schema change expected. Existing columns already hold title/author/source/themes/path/type.
- Modify `apple/Sources/MarpleKit/Vault/LocalVaultClient.swift`
  - Add a local helper only if a UI action needs to reveal/open the sibling `original.<ext>`; avoid protocol changes unless necessary.
- Modify `apple/Sources/MarpleKit/Markdown/AttributedStringRenderer.swift`
  - Render standard Markdown image syntax as an inline/block `NSTextAttachment` when an image resolver returns an `NSImage`.
- Modify `apple/Sources/Marple/Reading/MarkdownTextView.swift`
  - Pass an optional resolver into `MarkdownRenderer.render`.
- Modify `apple/Sources/Marple/Reading/DocView.swift`
  - Resolve relative image links from the open document path and workspace root if a `VaultClient` hook is added; otherwise leave image rendering as app-local follow-up.
- Tests:
  - `apple/Tests/MarpleKitTests/EntryDecodeTests.swift`
  - `apple/Tests/MarpleKitTests/IndexedEntryTests.swift`
  - Create `apple/Tests/MarpleKitTests/ImageAssetTests.swift`
  - `apple/Tests/MarpleKitTests/MarkdownModelTests.swift`

## Test Command

Use this command for Swift tests that import `Testing`:

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Run from `apple/`.

---

### Task 1: Model `type: image` entries

**Files:**
- Modify: `apple/Sources/MarpleKit/Model/Entry.swift`
- Test: `apple/Tests/MarpleKitTests/EntryDecodeTests.swift`
- Test: `apple/Tests/MarpleKitTests/IndexedEntryTests.swift`

- [ ] **Step 1: Write the failing entry type test**

Append to `EntryDecodeTests`:

```swift
@Test func testImageTypeIsModeled() {
    #expect(EntryType(rawValue: "image") == .image)
    #expect(EntryType.image.rawValue == "image")
    #expect(EntryType.image.label == "图片")
    #expect(EntryType.modeled.contains(.image))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter EntryDecodeTests/testImageTypeIsModeled
```

Expected: compile failure or test failure because `EntryType.image` does not exist.

- [ ] **Step 3: Implement the minimal model change**

In `Entry.swift`, add `.image` to `EntryType`, raw mapping, modeled order, and label:

```swift
case image

case "image": self = .image

case .image: return "image"

static let modeled: [EntryType] = [
    .paperAnalysis, .bookOverview, .authorProfile,
    .topicSynthesis, .chapterSummary, .note, .image,
]

case .image: return "图片"
```

- [ ] **Step 4: Update the existing modeled order expectation**

In `EntryDecodeTests.testModeledTypesOrderAndLabels`, update the expected array:

```swift
#expect(EntryType.modeled == [.paperAnalysis, .bookOverview, .authorProfile,
                              .topicSynthesis, .chapterSummary, .note, .image])
#expect(EntryType.image.label == "图片")
```

- [ ] **Step 5: Run tests to verify green**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter EntryDecodeTests
```

Expected: all `EntryDecodeTests` pass.

---

### Task 2: Index image metadata from `vault/images/<slug>/image.md`

**Files:**
- Modify: `apple/Tests/MarpleKitTests/IndexedEntryTests.swift`
- Modify only if needed: `apple/Sources/MarpleKit/Indexer/IndexedEntry.swift`

- [ ] **Step 1: Write the failing indexer behavior test**

Append to `IndexedEntryTests`:

```swift
@Test("image: indexes title author source themes from image.md")
func imageEntryMetadata() throws {
    let text = """
    ---
    type: image
    title: AI Agent Loop Diagram
    author: Alice Example
    source: https://example.com/agent-loop
    themes:
      - AI
      - architecture
    ---

    A diagram explaining the agent loop.
    """
    let outcome = build(text: text,
                        rel: "vault/images/ai-agent-loop-diagram/image.md",
                        fileStem: "image")
    guard case .indexed(let entry) = outcome else {
        Issue.record("Expected .indexed, got \(outcome)")
        return
    }

    #expect(entry.entryType == "image")
    #expect(entry.path == "vault/images/ai-agent-loop-diagram/image.md")
    #expect(entry.title == "AI Agent Loop Diagram")
    #expect(entry.author == "Alice Example")
    #expect(entry.source == "https://example.com/agent-loop")
    #expect(entry.themes == ["AI", "architecture"])
    #expect(entry.hasPDF == false)
    #expect(entry.pdfSlug == nil)
    #expect(entry.searchText.contains("AI Agent Loop Diagram"))
    #expect(entry.searchText.contains("Alice Example"))
    #expect(entry.searchText.contains("agent loop"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter IndexedEntryTests/imageEntryMetadata
```

Expected before Task 1: compile failure because `.image` is not modeled in downstream code, or after Task 1: pass if existing generic indexing already handles `type: image`. If it passes after Task 1, do not add production code for this task.

- [ ] **Step 3: Write minimal implementation only if the test fails for behavior**

If the test fails because image title fallback needs adjustment, use the existing non-note path in `buildIndexedEntry`:

```swift
let titleValue = (truthyText(frontmatter, "title")
    ?? truthyText(frontmatter, "name"))
    .map { stripWiki($0) }
```

No special image branch should be added unless a test proves it is needed.

- [ ] **Step 4: Run test to verify green**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter IndexedEntryTests/imageEntryMetadata
```

Expected: pass.

---

### Task 3: Resolve an image object's `original.<ext>` file by convention

**Files:**
- Create: `apple/Sources/MarpleKit/Model/ImageAsset.swift`
- Create: `apple/Tests/MarpleKitTests/ImageAssetTests.swift`

- [ ] **Step 1: Write failing tests for image object resolution**

Create `ImageAssetTests.swift`:

```swift
import Foundation
import Testing
@testable import MarpleKit

@Suite struct ImageAssetTests {
    @Test func originalPathUsesImageEntryDirectory() {
        let rel = ImageAsset.originalPath(forImageEntryPath: "vault/images/ai-agent-loop-diagram/image.md",
                                          existingFilenames: ["image.md", "original.png"])
        #expect(rel == "vault/images/ai-agent-loop-diagram/original.png")
    }

    @Test func originalPathSupportsCommonImageExtensions() {
        let rel = ImageAsset.originalPath(forImageEntryPath: "vault/images/photo/image.md",
                                          existingFilenames: ["image.md", "original.webp"])
        #expect(rel == "vault/images/photo/original.webp")
    }

    @Test func originalPathReturnsNilWhenNoOriginalImageExists() {
        let rel = ImageAsset.originalPath(forImageEntryPath: "vault/images/photo/image.md",
                                          existingFilenames: ["image.md", "notes.txt"])
        #expect(rel == nil)
    }

    @Test func objectSlugComesFromParentDirectory() {
        #expect(ImageAsset.slug(forImageEntryPath: "vault/images/ai-agent-loop-diagram/image.md") == "ai-agent-loop-diagram")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter ImageAssetTests
```

Expected: compile failure because `ImageAsset` does not exist.

- [ ] **Step 3: Implement the minimal helper**

Create `ImageAsset.swift`:

```swift
import Foundation

public enum ImageAsset {
    public static let originalStem = "original"
    public static let supportedExtensions = ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff"]

    public static func slug(forImageEntryPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? nil : parent
    }

    public static func originalPath(forImageEntryPath path: String,
                                    existingFilenames: [String]) -> String? {
        guard path.hasSuffix("/image.md") else { return nil }
        let match = supportedExtensions
            .map { "\(originalStem).\($0)" }
            .first { candidate in existingFilenames.contains(candidate) }
        guard let match else { return nil }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return dir + "/" + match
    }
}
```

- [ ] **Step 4: Run tests to verify green**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter ImageAssetTests
```

Expected: all `ImageAssetTests` pass.

---

### Task 4: Show image entries in the sidebar and browse list

**Files:**
- Modify: `apple/Sources/MarpleKit/Model/Entry.swift`
- Existing UI already uses `EntryType.modeled`, `EntryType.label`, and `EntryType.symbolName`.
- Test: `apple/Tests/MarpleKitTests/EntryDecodeTests.swift`

- [ ] **Step 1: Write the failing symbol test**

Find where `EntryType.symbolName` is defined. Add or update a test in `EntryDecodeTests`:

```swift
@Test func testImageTypeHasSymbolName() {
    #expect(EntryType.image.symbolName == "photo")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter EntryDecodeTests/testImageTypeHasSymbolName
```

Expected: compile failure or switch exhaustiveness failure until `.image` is handled by `symbolName`.

- [ ] **Step 3: Implement the minimal symbol mapping**

In the existing `symbolName` switch, add:

```swift
case .image: return "photo"
```

If `symbolName` is not in `Entry.swift`, edit the file where it is already defined and add only this case.

- [ ] **Step 4: Run tests to verify green**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter EntryDecodeTests
```

Expected: all `EntryDecodeTests` pass.

---

### Task 5: Render standard Markdown image syntax when an image resolver is supplied

**Files:**
- Modify: `apple/Sources/MarpleKit/Markdown/AttributedStringRenderer.swift`
- Modify: `apple/Tests/MarpleKitTests/MarkdownModelTests.swift`

- [ ] **Step 1: Write a failing renderer test**

Append to `MarkdownModelTests`:

```swift
@Test func renderedImageUsesAttachmentWhenResolverProvidesImage() throws {
    let image = NSImage(size: NSSize(width: 10, height: 5))
    let rendered = MarkdownRenderer.render("![alt](diagram.png)", style: Self.tableRenderStyle) { target in
        target == "diagram.png" ? image : nil
    }

    let attachment = try Self.attachment(in: rendered)
    #expect(attachment.bounds.width == 10)
    #expect(attachment.bounds.height == 5)
    #expect(!rendered.attributedString.string.contains("[alt]"))
}

private static func attachment(in rendered: RenderedDocument) throws -> NSTextAttachment {
    var found: NSTextAttachment?
    rendered.attributedString.enumerateAttribute(.attachment,
                                                 in: NSRange(location: 0, length: rendered.attributedString.length)) { value, _, stop in
        if let attachment = value as? NSTextAttachment {
            found = attachment
            stop.pointee = true
        }
    }
    return try #require(found)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter MarkdownModelTests/renderedImageUsesAttachmentWhenResolverProvidesImage
```

Expected: compile failure because `MarkdownRenderer.render` does not accept an image resolver, or test failure because images render as placeholder text.

- [ ] **Step 3: Implement the minimal renderer extension**

Change `MarkdownRenderer.render` signature to:

```swift
public static func render(_ markdown: String,
                          style: RenderStyle,
                          imageResolver: ((String) -> NSImage?)? = nil) -> RenderedDocument
```

Store the resolver in `RenderContext`:

```swift
let imageResolver: ((String) -> NSImage?)?

init(style: RenderStyle, imageResolver: ((String) -> NSImage?)?) {
    self.style = style
    self.imageResolver = imageResolver
    self.baseFont = style.bodyFont
    self.ps = style.bodyParagraphStyle
}
```

In the `Image` inline case, replace placeholder text with:

```swift
case let img as Image:
    if let destination = img.source, let image = imageResolver?(destination) {
        appendImage(image)
    } else {
        append(img.plainText.isEmpty ? "[image]" : "[\(img.plainText)]", color: .tertiaryLabelColor)
    }
```

Add a helper:

```swift
private func appendImage(_ image: NSImage) {
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NSRect(origin: .zero, size: image.size)
    attributed.append(NSAttributedString(attachment: attachment))
    newlines(2)
}
```

Use the exact Swift Markdown `Image` properties available in this package. If `img.source` or `img.plainText` do not compile, inspect `swift-markdown`'s `Image` API and use the equivalent destination/alt text properties.

- [ ] **Step 4: Run test to verify green**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter MarkdownModelTests/renderedImageUsesAttachmentWhenResolverProvidesImage
```

Expected: pass.

---

### Task 6: Verify the full native package

**Files:**
- No code changes unless tests expose a regression.

- [ ] **Step 1: Run full Swift tests**

Run:

```bash
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: all tests pass.

- [ ] **Step 2: Run Swift build**

Run:

```bash
cd apple && swift build
```

Expected: build succeeds.

- [ ] **Step 3: Manual GUI check**

Run the app and test on a small local fixture or the real vault:

```bash
cd apple && swift run Marple > /tmp/marple-app.log 2>&1
```

Expected manual checks:

- Sidebar includes `图片`.
- A fixture image entry at `vault/images/<slug>/image.md` appears under `图片`.
- Opening the image entry shows its metadata Markdown.
- A normal note with `![](../images/<slug>/original.png)` does not crash the reader.

---

## Self-Review

- Spec coverage: local file-first image directory, `image.md` metadata, `original.<ext>` convention, no MinIO, and image type browsing are covered.
- Placeholder scan: no `TBD` or open-ended implementation placeholders remain; Task 5 contains one API-inspection guard because `swift-markdown` image property names must be verified by compilation.
- Type consistency: `EntryType.image`, `ImageAsset.originalPath`, and `MarkdownRenderer.render(... imageResolver:)` are consistently named across tasks.
