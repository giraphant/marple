import Testing
import Foundation
@testable import MarpleKit

@Suite struct SemanticDocumentBuilderTests {
    private func tmpDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("semdoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func testTextStripsFrontmatterAndPrefixesTitle() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try """
        ---
        title: Ignored
        ---
        Body starts here.
        """.write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let entry = Entry(path: "note.md", type: .note, title: "Visible Title", author: [],
                          year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)

        let text = SemanticDocumentBuilder.text(workspaceRoot: dir.path, entry: entry)

        #expect(text == "Visible Title\nBody starts here.")
    }

    @Test func testTextCapsAfterTitleAndBodyJoin() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try "abcdef".write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let entry = Entry(path: "note.md", type: .note, title: "T", author: [],
                          year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)

        let text = SemanticDocumentBuilder.text(workspaceRoot: dir.path, entry: entry, cap: 4)

        #expect(text == "T\nab")
    }

    @Test func testMissingFileFallsBackToTitle() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let entry = Entry(path: "missing.md", type: .note, title: "Only Title", author: [],
                          year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)

        let text = SemanticDocumentBuilder.text(workspaceRoot: dir.path, entry: entry)

        #expect(text == "Only Title")
    }

    @Test func testDocKeepsEntryPath() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try "Body".write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let entry = Entry(path: "note.md", type: .note, title: nil, author: [],
                          year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)

        let doc = SemanticDocumentBuilder.doc(workspaceRoot: dir.path, entry: entry)

        #expect(doc.path == "note.md")
        #expect(doc.text == "Body")
    }
}
