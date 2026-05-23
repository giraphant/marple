import Testing
import Foundation
@testable import MarpleKit

@Suite struct NoteBuilderTests {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test func testIdeaNotePathAndFrontmatter() {
        let d = NoteBuilder.ideaNote(today: date(2026, 5, 23), stamp: "abcd")
        #expect(d.path == "vault/notes/2026-05-23-idea-abcd.md")
        #expect(d.title == "2026-05-23 — 新笔记")
        #expect(d.text.hasPrefix("---\n"))
        #expect(d.text.contains("type: note\n"))
        #expect(d.text.contains("created: 2026-05-23\n"))
        #expect(d.text.contains("themes: []\n"))
        #expect(d.text.contains("# 2026-05-23 — 新笔记"))
    }

    @Test func testAnnotationTargetsEntry() {
        let target = Entry(path: "vault/papers/marx-1867.md", type: .paperAnalysis,
                           title: "Capital", author: nil, year: nil, ratingScore: 0,
                           themes: [], preview: "", hasPDF: false)
        let d = NoteBuilder.annotation(target: target, today: date(2026, 5, 23), stamp: "wxyz")
        #expect(d.path == "vault/notes/marx-1867-note-wxyz.md")
        #expect(d.title == "对《Capital》的批注")
        #expect(d.text.contains("type: note\n"))
        #expect(d.text.contains("annotates: vault/papers/marx-1867.md\n"))
    }

    @Test func testAnnotationTitleFallsBackToFilenameStem() {
        let target = Entry(path: "vault/notes/loose-idea.md", type: .note,
                           title: nil, author: nil, year: nil, ratingScore: 0,
                           themes: [], preview: "", hasPDF: false)
        let d = NoteBuilder.annotation(target: target, today: date(2026, 5, 23), stamp: "0000")
        #expect(d.title == "对《loose-idea》的批注")
        #expect(d.path == "vault/notes/loose-idea-note-0000.md")
    }

    @Test func testAnnotationTitleWithColonIsQuoted() {
        let target = Entry(path: "vault/papers/x.md", type: .paperAnalysis,
                           title: "Marx: Capital", author: nil, year: nil, ratingScore: 0,
                           themes: [], preview: "", hasPDF: false)
        let d = NoteBuilder.annotation(target: target, today: date(2026, 5, 23), stamp: "0000")
        #expect(d.text.contains("title: \"对《Marx: Capital》的批注\"\n"))
    }

    @Test func testSlugifyCases() {
        #expect(NoteBuilder.slugify("Hello World") == "hello-world")
        #expect(NoteBuilder.slugify("a--b__c") == "a-b__c")
        #expect(NoteBuilder.slugify("中文标题") == "note")
        #expect(NoteBuilder.slugify("--trim--") == "trim")
    }
}
