import AppKit
import AVKit
import SwiftUI
import Testing
@testable import Marple
@testable import MarpleKit

@Suite(.serialized)
@MainActor
struct InteractionLifecycleTests {
    @Test func closingTalkStopsPlaybackBeforeTheViewDisappears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("recording.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: media, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            try file.write(from: buffer)
        }
        try "[00:01] Test".write(to: root.appendingPathComponent("talk.md"), atomically: true, encoding: .utf8)
        let client = LocalVaultClient(workspaceRoot: root.path,
                                     index: IndexDatabase(indexDBPath: root.appendingPathComponent("index.sqlite").path))
        let model = AppModel(client: client)
        model.catalog.mutateEntries { $0 = [Entry(path: "talk.md", type: .talk, title: "Test",
            author: [], year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)] }
        await model.open("talk.md")
        model.playTalk(seconds: 1)
        #expect(model.talkPlayback != nil)

        // Keep the view mounted: dismissal must stop audio before the removal
        // animation / onDisappear callback gets a chance to run.
        let host = NSHostingView(rootView: TalkPlayerView(model: model,
            availableSize: CGSize(width: 600, height: 400), enlarged: .constant(false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let nativeView = descendants(of: AVPlayerView.self, in: host).first
        let player = try #require(nativeView?.player)
        defer { player.pause() }
        for _ in 0..<100 {
            if player.timeControlStatus == .playing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.timeControlStatus == .playing)
        let escape = try keyEvent("\u{1b}", code: 53, window: window)
        // Escape activates the same close Button as clicking its × glyph.
        #expect(window.performKeyEquivalent(with: escape))
        #expect(model.talkPlayback == nil)
        #expect(player.rate == 0)
        #expect(player.currentItem == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.timeControlStatus == .paused)

        // The same controller must also support clicking another timestamp
        // immediately after closing, before SwiftUI finishes removing the view.
        model.playTalk(seconds: 2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.currentItem != nil)
        #expect(player.rate == 1)
        #expect(window.performKeyEquivalent(with: escape))
        #expect(player.rate == 0)
    }

    @Test func paletteSurvivesAppSwitchButClosesForAnOutsideClick() throws {
        let panel = CommandPalettePanel()
        panel.orderFront(nil)
        defer { panel.close() }
        panel.becomeKey()
        panel.resignKey()
        #expect(panel.isVisible)
        #expect(!panel.hidesOnDeactivate)

        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        // Reactivating the app can restore key status to its main window;
        // that alone is not an explicit dismissal of the search.
        other.becomeKey()
        #expect(panel.isVisible)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 30, y: 30), modifierFlags: [], timestamp: 0,
            windowNumber: other.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(click)
        #expect(!panel.isVisible)
    }

    @Test func paletteReusesItsSearchViewAfterLosingFocus() async throws {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        CommandPalettePresenter.toggle(model: model)
        let existing = NSApp.windows.compactMap { $0 as? CommandPalettePanel }.first { $0.isVisible }
        let panel = try #require(existing)
        defer {
            for window in NSApp.windows where window is CommandPalettePanel { window.close() }
        }
        let content = try #require(panel.contentView)
        try await Task.sleep(for: .milliseconds(100))
        let field = try #require(descendants(of: NSTextField.self, in: content).first { $0.isEditable })
        panel.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("retained query", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        panel.resignKey()
        #expect(panel.isVisible)
        CommandPalettePresenter.toggle(model: model)
        let reopened = NSApp.windows.compactMap { $0 as? CommandPalettePanel }.first { $0.isVisible }
        #expect(reopened === panel)
        #expect(reopened?.contentView === content)
        #expect(field.stringValue == "retained query")
        try await Task.sleep(for: .milliseconds(200))
        panel.close()
        CommandPalettePresenter.toggle(model: model)
        let fresh = NSApp.windows.compactMap { $0 as? CommandPalettePanel }.first { $0.isVisible }
        #expect(fresh !== panel)
        let freshContent = try #require(fresh?.contentView)
        try await Task.sleep(for: .milliseconds(100))
        let freshField = try #require(descendants(of: NSTextField.self, in: freshContent).first { $0.isEditable })
        #expect(freshField.stringValue.isEmpty)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: type, in: child)
        }
    }

    private func keyEvent(_ characters: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
