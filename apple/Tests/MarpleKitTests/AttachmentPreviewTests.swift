import AppKit
import AVKit
import GRDB
import SwiftUI
import Testing
import WebKit
@testable import Marple
@testable import MarpleKit

@MainActor @Suite(.serialized) struct AttachmentPreviewTests {
    private let path = "vault/webpages/saved-page/webpage.md"
    private let text = """
    ---
    type: webpage
    title: 保存的网页
    url: https://example.com/original-source
    site: Example Site
    captured_at: '2026-09-21T12:03:02Z'
    published: 2025-08-30
    themes: [网页存档]
    topics: [web-history]
    ---
    # 保存的网页
    正文仍然可以阅读。
    [录制](clip%20one.wav)
    """

    @Test func webpageIndexMetadataSearchAndReconcile() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexer = VaultIndexer(workspaceRoot: root.path)
        #expect(try indexer.buildFull() == 2)
        let dbPath = root.appendingPathComponent(".marple/index.sqlite").path
        let reader = IndexDatabase(indexDBPath: dbPath)
        let entry = try #require(reader.loadEntries().first { $0.path == path })
        #expect(entry.type == .webpage && entry.source == "Example Site")
        #expect(entry.created == "2026-09-21T12:03:02Z" && entry.date == "2025-08-30")
        #expect(entry.url == "https://example.com/original-source")
        #expect(EntryType.modeled.contains(.webpage) && AppPresentation.entryTypeLabel(.webpage) == "网页")
        #expect(entriesForPane(.type(.webpage), in: [entry]) == [entry])
        #expect(VaultConformance.check(entry, against: SchemaSnapshot(requiredByType:
            ["webpage": ["title", "url", "captured_at"]]))?.isConforming == true)
        for query in ["https://example.com/original-source", "original-source", "Example Site"] {
            #expect(searchEntries([entry], query).first?.entry == entry, "query=\(query)")
            #expect(try reader.search(query, type: .webpage, minRating: nil, theme: nil, limit: 10).first?.entry == entry)
        }
        #expect(inspectorInfoRows(for: entry).contains(.readOnlyScalar(label: "保存时间", value: entry.created!, copyValue: nil)))
        let optional = text.replacingOccurrences(of: "published: 2025-08-30", with: "published: null")
        guard case .indexed(let row) = buildIndexedEntry(text: optional, rel: path, fileStem: "webpage",
                                                        sourceSlugs: [], mtimeMs: nil) else {
            Issue.record("webpage was skipped"); return
        }
        #expect(row.date == nil && !row.hasPDF)
        // Previous versions skipped this type; reconcile must pick it up without a file edit.
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: "DELETE FROM entries WHERE type = 'webpage'")
        }
        #expect(try indexer.reconcile().upserted == 1)
        #expect(try reader.loadEntries().contains(entry))
    }

    @Test func localPathsAreDecodedAndConfinedToWorkspace() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(path).deletingLastPathComponent()
        let media = directory.appendingPathComponent("clip one.wav")
        for target in ["clip%20one.wav", "clip one.wav", media.absoluteString,
                       "vault/webpages/saved-page/clip%20one.wav#t=2"] {
            #expect(LocalAttachment.resolve(target, entryPath: path, workspaceRoot: root.path) == media)
        }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).pdf")
        try Data().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.pdf"), withDestinationURL: outside)
        for target in ["https://example.com/video.mp4", "missing.mp4", outside.absoluteString, "escape.pdf", "webpage.md"] {
            #expect(LocalAttachment.resolve(target, entryPath: path, workspaceRoot: root.path) == nil)
        }
    }

    @Test func nativeArchiveRendersAndMediaStopsOnCloseAndNavigation() async throws {
        _ = NSApplication.shared
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultIndexer(workspaceRoot: root.path).buildFull()
        let db = IndexDatabase(indexDBPath: root.appendingPathComponent(".marple/index.sqlite").path)
        let model = AppModel(client: LocalVaultClient(workspaceRoot: root.path, index: db), workspaceRoot: root.path)
        await model.loadIndex()
        await model.open(path)
        #expect(model.attachmentPreviewURL?.lastPathComponent == "snapshot.webarchive")
        #expect(model.canOpenOriginal)
        let host = NSHostingView(rootView: DocView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.close() }
        try await waitUntil { self.find(WKWebView.self, in: host)?.isLoading == false }
        let web = try #require(find(WKWebView.self, in: host))
        let title = try await web.evaluateJavaScript("document.title") as? String
        #expect(title?.isEmpty == false)
        let images = try await web.evaluateJavaScript("document.images.length") as? Int
        let loaded = try await web.evaluateJavaScript("[...document.images].filter(i=>i.naturalWidth>0).length") as? Int
        #expect(images != nil && images! > 0 && images == loaded)
        #expect(web.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        if let output = ProcessInfo.processInfo.environment["MARPLE_ATTACHMENT_SNAPSHOT"] {
            let image = try await web.takeSnapshot(configuration: nil)
            let data = try #require(image.tiffRepresentation)
            try #require(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output))
        }
        model.attachmentPreviewURL = nil
        try await waitUntil { self.find(WKWebView.self, in: host) == nil }
        await model.openOriginal()
        try await waitUntil { self.find(WKWebView.self, in: host) != nil }
        model.scrollTarget = 0
        try await waitUntil { model.attachmentPreviewURL == nil }
        // Markdown and wikilinks share the same local attachment resolver.
        await model.follow("clip%20one.wav")
        try await waitUntil { self.find(AVPlayerView.self, in: host)?.player?.currentItem?.status == .readyToPlay }
        let player = try #require(find(AVPlayerView.self, in: host)?.player)
        #expect(player.rate == 0)
        player.isMuted = true
        player.play()
        try await waitUntil { player.rate > 0 }
        model.attachmentPreviewURL = nil
        try await waitUntil { player.currentItem == nil && player.rate == 0 }
        #expect(player.rate == 0)

        let media = ProcessInfo.processInfo.environment["MARPLE_ATTACHMENT_MEDIA"] != nil ? "sample.mp4" : "clip%20one.wav"
        #expect(model.previewAttachment(media))
        try await waitUntil { self.find(AVPlayerView.self, in: host)?.player?.currentItem?.status == .readyToPlay }
        let nextPlayer = try #require(find(AVPlayerView.self, in: host)?.player)
        nextPlayer.isMuted = true
        nextPlayer.play()
        await model.open("vault/archives/minimal/archive.md")
        try await waitUntil { nextPlayer.currentItem == nil && nextPlayer.rate == 0 }
        #expect(nextPlayer.rate == 0 && model.attachmentPreviewURL == nil)
        #expect(model.openAttachments.isEmpty && !model.canOpenOriginal)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attachments-\(UUID())")
        let directory = root.appendingPathComponent(path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("vault/archives/minimal/archive.md")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\ntype: archive\ntitle: 无附件档案\nkind: document\ncreated: 2026-09-21\n---\n正文".write(to: archive, atomically: true, encoding: .utf8)
        let snapshot = directory.appendingPathComponent("snapshot.webarchive")
        if let source = ProcessInfo.processInfo.environment["MARPLE_ATTACHMENT_WEBARCHIVE"] {
            try FileManager.default.copyItem(atPath: source, toPath: snapshot.path)
        } else {
            let html = "<html><head><title>Saved page</title></head><body><h1>Archived page</h1><img src='https://example.com/pixel.svg'></body></html>"
            let resource: [String: Any] = ["WebMainResource": ["WebResourceURL": "https://example.com/",
                "WebResourceMIMEType": "text/html", "WebResourceTextEncodingName": "UTF-8", "WebResourceData": Data(html.utf8)],
                "WebSubresources": [["WebResourceURL": "https://example.com/pixel.svg", "WebResourceMIMEType": "image/svg+xml",
                    "WebResourceData": Data("<svg xmlns='http://www.w3.org/2000/svg' width='80' height='80'><rect width='80' height='80' fill='orange'/></svg>".utf8)]]]
            try PropertyListSerialization.data(fromPropertyList: resource, format: .binary, options: 0).write(to: snapshot)
        }
        // Ten seconds of silent PCM, independent of external media tools or files.
        var wav = Data("RIFF".utf8)
        func word(_ value: UInt32, bytes: Int = 4) { for i in 0..<bytes { wav.append(UInt8((value >> (8 * i)) & 255)) } }
        word(160036); wav.append(Data("WAVEfmt ".utf8)); word(16); word(1, bytes: 2); word(1, bytes: 2)
        word(8000); word(16000); word(2, bytes: 2); word(16, bytes: 2); wav.append(Data("data".utf8)); word(160000)
        wav.append(Data(count: 160000))
        try wav.write(to: directory.appendingPathComponent("clip one.wav"))
        if let source = ProcessInfo.processInfo.environment["MARPLE_ATTACHMENT_MEDIA"] {
            try FileManager.default.copyItem(atPath: source, toPath: directory.appendingPathComponent("sample.mp4").path)
        }
        return root
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        try #require(predicate())
    }
}
