import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

/// Issue #87 (侧边栏 Notes 卡顿): every inline-note autosave bumps the note's
/// mtime and triggers a reindex. `created` is date-only, so same-day notes always
/// tied and fell through to the mtime tiebreak — the card being edited jumped to
/// the end of the list after each autosave. Order must not depend on mtime.
@Suite struct InspectorNotesEditingTests {
    @MainActor
    @Test func annotationNotesOrderIgnoresMtime() async throws {
        let docPath = "vault/papers/p.md"
        let doc = Entry(path: docPath, type: .paper, title: "Paper", author: [],
                        year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        // Same created date; mtimes deliberately reversed relative to path order —
        // as after autosaving the FIRST note.
        let noteA = Entry(path: "vault/notes/p-note-aaaa.md", type: .note, title: "A",
                          author: [], year: nil, ratingScore: 0, themes: [], preview: "",
                          hasPDF: false, mtime: 2000, annotates: docPath, created: "2026-07-26")
        let noteB = Entry(path: "vault/notes/p-note-bbbb.md", type: .note, title: "B",
                          author: [], year: nil, ratingScore: 0, themes: [], preview: "",
                          hasPDF: false, mtime: 1000, annotates: docPath, created: "2026-07-26")
        let client = StubVaultClient(
            entries: [doc, noteA, noteB],
            texts: [docPath: "---\ntype: paper\n---\n\n# Paper\n"])
        let model = AppModel(client: client)
        await model.loadIndex()
        await model.open(docPath)

        // The relation graph builds in a deferred detached task; wait for the
        // annotations to land before asserting their order.
        for _ in 0..<200 where model.inspectorAnnotationNotes.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(model.inspectorAnnotationNotes.map(\.path) == [noteA.path, noteB.path])
    }
}
