import AppKit
import SwiftUI
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor @Suite(.serialized) struct ArchiveManifestTests {
    private let path = "vault/archives/repair/archive.md"
    private let body = """
    ---
    type: archive
    title: 屏幕维修记录
    kind: thread
    created: 2026-09-21
    source: 旧出处
    url: https://legacy.example.org/
    ---
    # 屏幕维修记录
    原帖中的屏幕与排线照片，以及补充演示。

    ![屏幕照片](originals/001-screen.png)

    [演示](originals/002-demo.bin)
    """

    private let manifest = """
    schema_version: quasi.archive.manifest/0.2
    source:
      url: https://example.org/repair
      title: 屏幕维修讨论
    files:
      - path: originals/001-screen.png
        title: 屏幕色偏细节
        description: 原帖展示屏幕色偏的照片。
        media_type: image/png
        captured_at: '2026-09-21T12:00:00+00:00'
        size: 120
        sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        url: https://cdn.example.org/screen.png
      - path: originals/002-demo.bin
        title: 屏幕拆卸演示
        description: 来源页面附带的演示视频，未逐帧核读。
        media_type: video/mp4
        captured_at: '2026-09-21T12:02:00+00:00'
        size: 4096
        sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        url: https://cdn.example.org/demo.mp4
        source:
          url: https://other.example.org/demo
          title: 补充演示
      - path: originals/003-missing.pdf
        title: 维修手册
        description: 补充维修步骤的 PDF 手册。
        media_type: application/pdf
        captured_at: '2026-09-21T12:03:00+00:00'
        size: 2048
        sha256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        url: https://example.org/manual.pdf
    coverage: 收录正文配图与演示；未收录评论。
    """

    @Test func sourceInheritanceMIMEOrderAndMissingOriginals() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try #require(try ArchiveManifest.load(entryPath: path, workspaceRoot: root.path))
        #expect(inventory.files[0].title == "屏幕色偏细节")
        #expect(inventory.files[0].description == "原帖展示屏幕色偏的照片。")
        #expect(inventory.files.map(\.path) == ["originals/001-screen.png", "originals/002-demo.bin", "originals/003-missing.pdf"])
        #expect(inventory.source(for: inventory.files[0]).url == "https://example.org/repair")
        #expect(inventory.source(for: inventory.files[1]).url == "https://other.example.org/demo")
        #expect(inventory.localURL(for: inventory.files[2], entryPath: path, workspaceRoot: root.path) == nil)
        let movie = try #require(inventory.localURL(for: inventory.files[1], entryPath: path, workspaceRoot: root.path))
        #expect(LocalAttachment.previewKind(movie, mediaType: inventory.files[1].mediaType) == .media)
        #expect(LocalAttachment.previewKind(movie, mediaType: "application/octet-stream") == .unsupported)
        #expect(LocalAttachment.resolve("https://example.org/x.bin", entryPath: path, workspaceRoot: root.path,
                                        mediaType: "video/mp4") == nil)
    }

    @Test func emptyInvalidAndUnsafeManifests() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(path).deletingLastPathComponent().appendingPathComponent("manifest.yaml")
        try FileManager.default.removeItem(at: file)
        #expect(try ArchiveManifest.load(entryPath: path, workspaceRoot: root.path) == nil)
        let empty = "schema_version: quasi.archive.manifest/0.2\nsource: {url: 'https://example.org/'}\nfiles: []\ncoverage: 仅保存出处\n"
        try empty.write(to: file, atomically: true, encoding: .utf8)
        #expect(try ArchiveManifest.load(entryPath: path, workspaceRoot: root.path)?.files.isEmpty == true)
        for invalid in [manifest.replacingOccurrences(of: "quasi.archive.manifest/0.2", with: "quasi.archive.manifest/0.1"),
                        manifest.replacingOccurrences(of: "    title: 屏幕色偏细节\n", with: ""),
                        manifest.replacingOccurrences(of: "    description: 原帖展示屏幕色偏的照片。\n", with: ""),
                        manifest.replacingOccurrences(of: "title: 屏幕色偏细节", with: "title: '   '"),
                        manifest.replacingOccurrences(of: "description: 原帖展示屏幕色偏的照片。", with: "description: '   '"),
                        manifest.replacingOccurrences(of: "originals/001-screen.png", with: "../outside.png"),
                        manifest.replacingOccurrences(of: "quasi.archive.manifest/0.2", with: "unknown/9"),
                        manifest.replacingOccurrences(of: "originals/002-demo.bin", with: "originals/001-screen.png")] {
            try invalid.write(to: file, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) { try ArchiveManifest.load(entryPath: path, workspaceRoot: root.path) }
        }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).bin")
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = file.deletingLastPathComponent().appendingPathComponent("originals/escape.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(LocalAttachment.resolve("originals/escape.bin", entryPath: path, workspaceRoot: root.path,
                                        mediaType: "audio/wav") == nil)
    }

    @Test func readerArrowKeysStayInsideArchiveAndRespectFocus() async throws {
        _ = NSApplication.shared
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultIndexer(workspaceRoot: root.path).buildFull()
        let model = AppModel(client: LocalVaultClient(workspaceRoot: root.path,
            index: IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path)), workspaceRoot: root.path)
        await model.loadIndex()
        await model.open(path)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let reader = NSView(frame: NSRect(x: 200, y: 0, width: 400, height: 400))
        let text = NSTextView(frame: reader.bounds)
        text.isEditable = false
        reader.addSubview(text)
        window.contentView?.addSubview(reader)
        let keyboard = ArchiveReaderKeyboard(model: model, reader: reader)
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        window.makeFirstResponder(text)
        #expect(!keyboard.handle(key(124, .shift)))
        #expect(model.attachmentPreviewURL == nil)
        #expect(keyboard.handle(key(124)))
        #expect(model.selectedArchiveFile?.path == "originals/001-screen.png")
        #expect(keyboard.handle(key(124)))
        #expect(model.selectedArchiveFile?.path == "originals/002-demo.bin")
        #expect(keyboard.handle(key(124))) // Missing PDF skipped; stop at end.
        #expect(model.selectedArchiveFile?.path == "originals/002-demo.bin")
        #expect(keyboard.handle(key(123)))
        #expect(keyboard.handle(key(123)))
        #expect(model.attachmentPreviewURL == nil)
        #expect(keyboard.handle(key(123))) // Stop at body.
        #expect(model.openPath == path)
        let outside = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        window.contentView?.addSubview(outside)
        window.makeFirstResponder(outside)
        #expect(!keyboard.handle(key(124)))
        text.isEditable = true
        window.makeFirstResponder(text)
        #expect(!keyboard.handle(key(124)))
        #expect(model.attachmentPreviewURL == nil)
    }

    @Test func readerImagesInspectorRefreshAndNavigation() async throws {
        _ = NSApplication.shared
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultIndexer(workspaceRoot: root.path).buildFull()
        let db = IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path)
        let model = AppModel(client: LocalVaultClient(workspaceRoot: root.path, index: db), workspaceRoot: root.path)
        await model.loadIndex()
        await model.open(path)
        #expect(model.attachmentPreviewURL == nil) // Archive opens its authored arrangement.
        #expect(model.openAttachments.count == 2)
        #expect(model.openArchiveManifest?.files.count == 3)
        let entry = try #require(model.openEntry)
        let rows = inspectorInfoRows(for: entry, archiveManifest: model.openArchiveManifest)
        #expect(rows.contains(.readOnlyScalar(label: "来源", value: "旧出处", copyValue: nil)))
        #expect(inspectorInfoRows(for: entry).contains(.readOnlyScalar(label: "来源", value: "旧出处", copyValue: nil)))
        let rendered = MarkdownRenderer.render(model.openBody, style: RenderStyle(size: 16, fontFamily: nil, lineHeight: 1.5),
                                               imageURLs: model.archiveImageURLs)
        var imageCount = 0
        rendered.attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.attributedString.length)) { value, range, _ in
            if let image = value as? NSTextAttachment {
                imageCount += 1
                #expect(image.image != nil)
                #expect(rendered.attributedString.attribute(.link, at: range.location, effectiveRange: nil) is URL)
                let bounds = image.attachmentBounds(for: nil, proposedLineFragment: NSRect(x: 0, y: 0, width: 20, height: 100),
                                                    glyphPosition: .zero, characterIndex: range.location)
                #expect(bounds.width <= 20 && bounds.height > 0)
            }
        }
        #expect(imageCount == 1)
        #expect(model.previewAttachment("originals/002-demo.bin"))
        #expect(model.selectedArchiveFile?.source?.title == "补充演示")
        #expect(model.selectedArchiveFile?.title == "屏幕拆卸演示")
        #expect(model.selectedArchiveFile?.description == "来源页面附带的演示视频，未逐帧核读。")
        model.attachmentPreviewURL = nil

        if let output = ProcessInfo.processInfo.environment["MARPLE_ARCHIVE_SNAPSHOT"] {
            let host = NSHostingView(rootView: HStack(spacing: 0) {
                DocView(model: model).frame(width: 680)
                Divider()
                InspectorView(model: model).frame(width: 300)
            }.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 981, height: 760),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }

        #expect(model.previewAttachment("originals/001-screen.png"))
        let manifestURL = root.appendingPathComponent(path).deletingLastPathComponent().appendingPathComponent("manifest.yaml")
        try "schema_version: quasi.archive.manifest/0.2\nsource: {url: 'https://new.example.org/'}\nfiles: []\ncoverage: 仅保存出处\n"
            .write(to: manifestURL, atomically: true, encoding: .utf8)
        await model.reloadOpen()
        #expect(model.openArchiveManifest?.source.url == "https://new.example.org/")
        #expect(model.openAttachments.isEmpty && model.archiveImageURLs.isEmpty)
        #expect(model.attachmentPreviewURL == nil)
        try "invalid: [".write(to: manifestURL, atomically: true, encoding: .utf8)
        await model.reloadOpen()
        #expect(model.archiveManifestError != nil && model.openArchiveManifest == nil)
        await model.open("vault/notes/other.md")
        #expect(model.archiveManifestError == nil && model.openArchiveManifest == nil)
        #expect(model.openAttachments.isEmpty && model.attachmentPreviewURL == nil)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-manifest-\(UUID())").resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("originals"), withIntermediateDirectories: true)
        try body.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try manifest.write(to: directory.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
        let image = NSImage(size: NSSize(width: 400, height: 240))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 400, height: 240)).fill()
        image.unlockFocus()
        let bitmap = try #require(NSBitmapImageRep(data: image.tiffRepresentation!))
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("originals/001-screen.png"))
        try Data([0]).write(to: directory.appendingPathComponent("originals/002-demo.bin"))
        let note = root.appendingPathComponent("vault/notes/other.md")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\ntype: note\ntitle: Other\n---\nOther".write(to: note, atomically: true, encoding: .utf8)
        return root
    }
}
