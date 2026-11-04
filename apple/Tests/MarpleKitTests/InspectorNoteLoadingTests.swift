import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@Suite @MainActor struct InspectorNoteLoadingTests {
    private static let note = Entry(path: "vault/notes/load.md", type: .note, title: "Note",
                                    author: [], year: nil, ratingScore: 0, themes: [],
                                    preview: "", hasPDF: false, annotates: "vault/papers/a.md")

    @Test func concurrentLoadsShareOneReadAndBothAwaitPublication() async throws {
        let client = DelayedNoteClient()
        let model = AppModel(client: client)
        let first = Task { await model.ensureInspectorNoteLoaded(Self.note) }
        try await waitForReads(1, client)
        var secondReturned = false
        let second = Task {
            await model.ensureInspectorNoteLoaded(Self.note)
            secondReturned = true
        }
        // Both requests have a chance to enter while the first I/O is suspended.
        try await Task.sleep(for: .milliseconds(20))
        #expect(!secondReturned)
        #expect(await client.gate.count == 1)
        await client.gate.finishAll(.success("disk body"))
        await first.value
        await second.value
        #expect(model.inspectorNoteDraft(for: Self.note.path) == "disk body")
        #expect(!model.hasDirtyInspectorNotes)
    }

    @Test(arguments: ["local edit", "", "disk body"])
    func loadingDoesNotOverwriteAnEditedDraft(_ draft: String) async throws {
        let client = DelayedNoteClient()
        let model = AppModel(client: client)
        let load = Task { await model.ensureInspectorNoteLoaded(Self.note) }
        try await waitForReads(1, client)
        model.setInspectorNoteDraft(draft, for: Self.note)
        await client.gate.finishAll(.success("disk body"))
        await load.value
        #expect(model.inspectorNoteDraft(for: Self.note.path) == draft)
        let isDirty = model.hasDirtyInspectorNotes
        #expect(isDirty == (draft != "disk body"))
    }

    @Test func oldSuccessCannotRepopulateNotesAfterDocumentSwitch() async throws {
        let client = DelayedNoteClient()
        let model = AppModel(client: client)
        await model.loadIndex()
        let old = Task { await model.ensureInspectorNoteLoaded(Self.note) }
        try await waitForReads(1, client)
        model.setInspectorNoteFocused(Self.note, focused: true)
        await model.open("vault/papers/b.md")
        await client.gate.finishAll(.success("old body"))
        await old.value
        #expect(model.inspectorNoteDrafts[Self.note.path] == nil)
        #expect(model.inspectorNoteStatuses[Self.note.path] == nil)
    }

    @Test func oldFailureCannotReplaceNewLoadStatus() async throws {
        let client = DelayedNoteClient()
        let model = AppModel(client: client)
        await model.loadIndex()
        let old = Task { await model.ensureInspectorNoteLoaded(Self.note) }
        try await waitForReads(1, client)
        model.setInspectorNoteFocused(Self.note, focused: true)
        await model.open("vault/papers/b.md")
        let fresh = Task { await model.ensureInspectorNoteLoaded(Self.note) }
        try await waitForReads(2, client)
        await client.gate.finish(1, .success("fresh body"))
        await fresh.value
        await client.gate.finish(0, .failure(VaultError.notFound("old request")))
        await old.value
        #expect(model.inspectorNoteDraft(for: Self.note.path) == "fresh body")
        #expect(model.inspectorNoteStatus(for: Self.note.path) == .idle)
        #expect(model.writeError == nil)
    }

    @Test func oldFailureIsIgnoredAfterDocumentSwitch() async throws {
        let client = DelayedNoteClient()
        let model = AppModel(client: client)
        await model.loadIndex()
        let old = Task { await model.ensureInspectorNoteLoaded(Self.note) }
        try await waitForReads(1, client)
        model.setInspectorNoteFocused(Self.note, focused: true)
        await model.open("vault/papers/b.md")
        await client.gate.finishAll(.failure(VaultError.notFound("old request")))
        await old.value
        #expect(model.inspectorNoteStatuses[Self.note.path] == nil)
        #expect(model.writeError == nil)
    }

    @Test func failedLoadCanBeRetried() async throws {
        let client = DelayedNoteClient()
        let model = AppModel(client: client)
        let first = Task { await model.ensureInspectorNoteLoaded(Self.note) }
        try await waitForReads(1, client)
        await client.gate.finishAll(.failure(VaultError.notFound("first request")))
        await first.value
        if case .failed = model.inspectorNoteStatus(for: Self.note.path) {} else {
            Issue.record("Expected a visible current-load error")
        }
        let retry = Task { await model.ensureInspectorNoteLoaded(Self.note) }
        try await waitForReads(2, client)
        await client.gate.finishAll(.success("retry body"))
        await retry.value
        #expect(model.inspectorNoteDraft(for: Self.note.path) == "retry body")
        #expect(model.inspectorNoteStatus(for: Self.note.path) == .idle)
    }

    @Test func lateLoadDoesNotUndoACompletedSave() async throws {
        let client = DelayedNoteClient()
        let model = AppModel(client: client)
        let load = Task { await model.ensureInspectorNoteLoaded(Self.note) }
        try await waitForReads(1, client)
        model.saveInspectorNoteDraft("saved edit", for: Self.note)
        try await waitForReads(2, client)
        await client.gate.finish(1, .success("disk body"))
        for _ in 0..<200 where model.hasDirtyInspectorNotes {
            try await Task.sleep(for: .milliseconds(5))
        }
        let dirtyBeforeLoadReturns = model.hasDirtyInspectorNotes
        #expect(!dirtyBeforeLoadReturns)
        await client.gate.finish(0, .success("older body"))
        await load.value
        #expect(model.inspectorNoteDraft(for: Self.note.path) == "saved edit")
        let dirtyAfterLoadReturns = model.hasDirtyInspectorNotes
        #expect(!dirtyAfterLoadReturns)
    }

    private func waitForReads(_ count: Int, _ client: DelayedNoteClient) async throws {
        for _ in 0..<200 {
            if await client.gate.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Release all waiting continuations even on a broken implementation.
        await client.gate.finishAll(.failure(VaultError.notFound("test timeout")))
        try #require(await client.gate.count >= count)
    }
}

private actor NoteReadGate {
    private var requests: [Int: CheckedContinuation<String, Error>] = [:]
    private(set) var count = 0
    func read() async throws -> String {
        let id = count
        count += 1
        // Deliberately ignores cancellation: a stale provider reply must still
        // be rejected by AppModel, even if I/O cannot be interrupted.
        return try await withCheckedThrowingContinuation { requests[id] = $0 }
    }
    func finish(_ id: Int, _ result: Result<String, Error>) {
        requests.removeValue(forKey: id)?.resume(with: result)
    }
    func finishAll(_ result: Result<String, Error>) {
        let pending = requests
        requests.removeAll()
        for continuation in pending.values { continuation.resume(with: result) }
    }
}

private struct DelayedNoteClient: VaultClient {
    let gate = NoteReadGate()
    func index() async throws -> [Entry] {
        [Entry(path: "vault/papers/b.md", type: .paper, title: "B", author: [],
               year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)]
    }
    func entryText(path: String) async throws -> String {
        if path.hasPrefix("vault/notes/") { return try await gate.read() }
        return "Document B"
    }
    func search(_ query: SearchQuery) async throws -> [SearchHit] { [] }
    func openInEditor(path: String, app: String) async throws {}
    func openPDF(slug: String) async throws {}
    func openTranslation(slug: String) async throws {}
    func hasTranslation(slug: String) -> Bool { false }
    func imageOriginalURL(forImageEntryPath path: String) async throws -> URL? { nil }
    func fileURL(for path: String) -> URL? { nil }
    func createImageObject(from sourceURL: URL, title: String?) async throws -> Entry {
        throw VaultError.notFound(sourceURL.path)
    }
    func writeFile(path: String, text: String) async throws {}
    func createNote(path: String, text: String) async throws {}
    func moveToTrash(path: String) async throws -> String { "" }
    func listTrash() async throws -> [TrashItem] { [] }
    func restoreTrash(name: String) async throws -> String { "" }
    func purgeTrash(name: String) async throws {}
}
