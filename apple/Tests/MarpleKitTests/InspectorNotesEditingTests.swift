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

    /// While typing, drafts are only staged in memory (an eager disk write per
    /// typing pause triggered a full reindex that stuttered IME input); the
    /// write must land on commit (blur/doc-switch/quit).
    @MainActor
    @Test func stagingDoesNotWriteUntilCommit() async throws {
        let notePath = "vault/notes/p-note-aaaa.md"
        let note = Entry(path: notePath, type: .note, title: "A", author: [],
                         year: nil, ratingScore: 0, themes: [], preview: "",
                         hasPDF: false, annotates: "vault/papers/p.md", created: "2026-07-26")
        let client = StubVaultClient(
            entries: [note],
            texts: [notePath: "---\ntype: note\n---\n\nold\n"])
        let model = AppModel(client: client)
        await model.loadIndex()
        await model.ensureInspectorNoteLoaded(note)

        model.setInspectorNoteDraft("new text", for: note)
        #expect(model.hasDirtyInspectorNotes)
        #expect(client.writeLog.last == nil)

        model.saveInspectorNoteDraft("new text", for: note)
        for _ in 0..<200 where client.writeLog.last == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(client.writeLog.last?.path == notePath)
        #expect(model.hasDirtyInspectorNotes == false)
    }

    @MainActor
    @Test func bookNoteIsVisibleAndEditableFromEveryChapter() async throws {
        let overviewPath = "vault/books/book/00-overview.md"
        let chapter1Path = "vault/books/book/01-one.md"
        let chapter2Path = "vault/books/book/02-two.md"
        let notePath = "vault/notes/book-note.md"
        let overview = Entry(path: overviewPath, type: .book, title: "Book", author: [],
                             year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let chapter1 = Entry(path: chapter1Path, type: .chapter, title: "One", author: [],
                             year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false,
                             book: "book")
        let chapter2 = Entry(path: chapter2Path, type: .chapter, title: "Two", author: [],
                             year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false,
                             book: "book")
        let note = Entry(path: notePath, type: .note, title: "Book note", author: [],
                         year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false,
                         annotates: overviewPath, created: "2026-07-30")
        let client = StubVaultClient(
            entries: [overview, chapter1, chapter2, note],
            texts: [
                chapter1Path: "---\ntype: chapter\n---\n\n# One\n",
                chapter2Path: "---\ntype: chapter\n---\n\n# Two\n",
                notePath: "---\ntype: note\nannotates: \(overviewPath)\n---\n\nold\n",
            ])
        let model = AppModel(client: client)
        await model.loadIndex()

        await model.open(chapter1Path)
        for _ in 0..<200 where model.inspectorAnnotationNotes.map(\.path) != [notePath] {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.inspectorAnnotationNotes.map(\.path) == [notePath])

        await model.open(chapter2Path)
        for _ in 0..<200 where model.inspectorAnnotationNotes.map(\.path) != [notePath] {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.inspectorAnnotationNotes.map(\.path) == [notePath])

        await model.ensureInspectorNoteLoaded(note)
        model.saveInspectorNoteDraft("edited from chapter two", for: note)
        for _ in 0..<200 where client.writeLog.last == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(client.writeLog.last?.path == notePath)
        #expect(client.writeLog.last?.text.contains("edited from chapter two") == true)
    }

    @MainActor
    @Test func inlineNoteCreatedFromChapterTargetsBookOverview() async throws {
        let overviewPath = "vault/books/book/00-overview.md"
        let chapterPath = "vault/books/book/01-one.md"
        let overview = Entry(path: overviewPath, type: .book, title: "Book", author: [],
                             year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let chapter = Entry(path: chapterPath, type: .chapter, title: "One", author: [],
                            year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false,
                            book: "book")
        let client = StubVaultClient(
            entries: [overview, chapter],
            texts: [chapterPath: "---\ntype: chapter\n---\n\n# One\n"])
        let model = AppModel(client: client)
        await model.loadIndex()
        await model.open(chapterPath)

        await model.createInlineAnnotationForOpenDoc()

        #expect(client.createLog.created.count == 1)
        #expect(client.createLog.created[0].text.contains("annotates: \(overviewPath)"))
        #expect(model.inspectorAnnotationNotes.first?.annotates == overviewPath)
    }
}
