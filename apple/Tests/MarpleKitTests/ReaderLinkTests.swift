import AppKit
import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct ReaderLinkTests {
    private let source = "vault/topics/power/02-outline.md"
    private let guide = "vault/topics/power/03-materials-guide.md"

    @MainActor
    @Test func tableLinkOpensSiblingDocumentAtChineseHeading() async throws {
        let markdown = """
        | 阅读入口 |
        | --- |
        | [换电与备用](03-materials-guide.md#更换电池和携带备用电池) |
        """
        let rendered = MarkdownRenderer.render(markdown, style: RenderStyle(size: 16, fontFamily: nil, lineHeight: 1.5))
        let range = (rendered.attributedString.string as NSString).range(of: "换电与备用")
        let link = try #require(rendered.attributedString.attribute(.link, at: range.location,
                                                                   effectiveRange: nil))
        var clicked: URL?
        let coordinator = MarkdownTextView.Coordinator { clicked = $0; return true }
        #expect(coordinator.textView(NSTextView(), clickedOnLink: link, at: range.location))
        let destination = ReaderLink.resolve(try #require(clicked), from: source, workspaceRoot: "/tmp/vault")
        #expect(destination == .document(path: guide, fragment: "更换电池和携带备用电池"))

        let body = "# 材料导读\n\n## 更换电池和携带备用电池\n\n内容"
        let model = AppModel(client: StubVaultClient(entries: [entry(source), entry(guide)],
                                                    texts: [source: markdown, guide: body]))
        await model.loadIndex()
        await model.open(source)
        await model.followDocumentLink(path: guide, fragment: "更换电池和携带备用电池")
        #expect(model.openPath == guide)
        let jump = try #require(model.headingJump)
        let headings = MarkdownRenderer.render(model.openBody, style: RenderStyle(size: 16, fontFamily: nil, lineHeight: 1.5)).headings
        #expect(ReaderLink.headingRange(for: jump.fragment, in: headings) == headings[1].range)
        await model.goBack()
        #expect(model.openPath == source)
        #expect(model.headingJump == nil)
    }

    @Test func resolvesLocalAndExternalDestinations() throws {
        let cases: [(String, ReaderLink)] = [
            ("#使用插座-车电和机上电源", .document(path: source, fragment: "使用插座-车电和机上电源")),
            ("../notes/中文%20材料.md", .document(path: "vault/topics/notes/中文 材料.md", fragment: nil)),
            ("../notes/100%2520.md", .document(path: "vault/topics/notes/100%20.md", fragment: nil)),
            ("file:///tmp/vault/" + guide + "#battery", .document(path: guide, fragment: "battery")),
            ("03-materials-guide.md", .document(path: guide, fragment: nil)),
            ("https://example.com/a#b", .external(URL(string: "https://example.com/a#b")!)),
            ("mailto:reader@example.com", .external(URL(string: "mailto:reader@example.com")!)),
            ("//example.com/a", .external(URL(string: "https://example.com/a")!)),
            ("manual.pdf", .external(URL(fileURLWithPath: "/tmp/vault/vault/topics/power/manual.pdf"))),
        ]
        for (raw, expected) in cases {
            let url = try #require(ReaderLink.url(from: raw))
            let result = ReaderLink.resolve(url, from: source, workspaceRoot: "/tmp/vault")
            #expect(result == expected, "Link: \(raw)")
        }
    }

    @Test func headingAnchorsHandleTitleFormattingAndDuplicates() {
        let body = "# Title\n\n## 使用插座 车电和机上电源\n\n## **Battery** & `USB`!\n\n## Battery & USB!"
        let headings = MarkdownRenderer.render(body, style: RenderStyle(size: 16, fontFamily: nil, lineHeight: 1.5)).headings
        #expect(ReaderLink.headingRange(for: "title", in: headings) == headings[0].range)
        #expect(ReaderLink.headingRange(for: "使用插座-车电和机上电源", in: headings) == headings[1].range)
        #expect(ReaderLink.headingRange(for: "battery--usb", in: headings) == headings[2].range)
        #expect(ReaderLink.headingRange(for: "battery--usb-1", in: headings) == headings[3].range)
        #expect(ReaderLink.headingRange(for: "missing", in: headings) == nil)
        #expect(ReaderLink.headingRange(for: "", in: headings) == NSRange(location: 0, length: 0))
    }

    @MainActor
    @Test func sameDocumentJumpCanRepeatAndMissingDocumentStaysInReader() async throws {
        let model = AppModel(client: StubVaultClient(entries: [entry(source)], texts: [source: "# A\n\n## B"]))
        await model.loadIndex()
        await model.open(source)
        let tabs = model.tabs.count
        await model.followDocumentLink(path: source, fragment: "b")
        let first = try #require(model.headingJump)
        await model.followDocumentLink(path: source, fragment: "b")
        #expect(model.headingJump?.id != first.id)
        #expect(model.tabs.count == tabs)
        #expect(!model.canGoBack)
        await model.followDocumentLink(path: guide, fragment: nil)
        #expect(model.openPath == source)
        #expect(model.toast != nil)
    }

    private func entry(_ path: String) -> Entry {
        Entry(path: path, type: .topic, title: path, author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }
}
