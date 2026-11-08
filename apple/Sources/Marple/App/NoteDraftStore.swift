import Foundation
import MarpleKit
import Observation

/// Right-rail note drafts, shared by every window: one draft, disk baseline, save
/// status and save task per note path, so two windows showing the same note edit
/// the same text and never overwrite each other with private copies.
///
/// Windows register the paths they show (`retain`) and drop them when they leave
/// the document (`release`). An entry nobody shows is dropped once it is clean;
/// a dirty one (e.g. its save failed) stays so the text is not lost.
@Observable @MainActor
final class NoteDraftStore {
    @ObservationIgnored private let client: VaultClient
    @ObservationIgnored private let catalog: Catalog

    private(set) var drafts: [String: String] = [:]
    private(set) var originals: [String: String] = [:]
    private(set) var statuses: [String: InspectorNoteStatus] = [:]
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadTasks: [String: (token: UUID, task: Task<String?, Never>)] = [:]
    @ObservationIgnored private var holders: [String: Set<ObjectIdentifier>] = [:]

    init(client: VaultClient, catalog: Catalog) {
        self.client = client
        self.catalog = catalog
    }

    /// Unsaved staged edits anywhere (the quit hook only delays termination when true).
    var hasDirty: Bool { drafts.contains { originals[$0.key] != $0.value } }

    func retain(_ path: String, by holder: AnyObject) {
        holders[path, default: []].insert(ObjectIdentifier(holder))
    }

    func paths(heldBy holder: AnyObject) -> [String] {
        let id = ObjectIdentifier(holder)
        return holders.compactMap { $0.value.contains(id) ? $0.key : nil }
    }

    /// `holder` no longer shows its notes. Notes nobody shows lose in-flight loads
    /// and, when clean, their entries.
    func release(_ holder: AnyObject) {
        let id = ObjectIdentifier(holder)
        for path in paths(heldBy: holder) {
            holders[path]?.remove(id)
            guard holders[path]?.isEmpty != false else { continue }
            holders[path] = nil
            loadTasks.removeValue(forKey: path)?.task.cancel()
            if let draft = drafts[path], draft != originals[path] { continue }
            saveTasks.removeValue(forKey: path)?.cancel()
            drafts[path] = nil
            originals[path] = nil
            statuses[path] = nil
        }
    }

    /// Read the note's body once, shared by every window asking for it. Returns
    /// the load error, if any, for the caller to surface.
    @discardableResult
    func load(_ path: String) async -> String? {
        guard drafts[path] == nil else { return nil }
        if let pending = loadTasks[path] {
            _ = await pending.task.value
            return nil
        }
        statuses[path] = .loading
        let token = UUID()
        let task = Task { () -> String? in
            defer { if loadTasks[path]?.token == token { loadTasks[path] = nil } }
            do {
                let raw = try await client.entryText(path: path)
                guard !Task.isCancelled, holders[path] != nil else { return nil }
                // A save may already have established a newer disk baseline.
                guard originals[path] == nil else { return nil }
                let body = Frontmatter.split(raw).body
                originals[path] = body
                if let draft = drafts[path] {
                    // Preserve edits made while reading, including clearing the note.
                    if statuses[path] != .saving {
                        statuses[path] = draft == body ? .saved : .dirty
                        if draft != body { scheduleSave(path) }
                    }
                } else {
                    drafts[path] = body
                    statuses[path] = .idle
                }
                return nil
            } catch {
                guard !Task.isCancelled, holders[path] != nil, drafts[path] == nil else { return nil }
                statuses[path] = .failed("\(error)")
                print("[marple] load note FAILED \(path): \(error)")
                return "\(error)"
            }
        }
        loadTasks[path] = (token, task)
        return await task.value
    }

    /// Stage typing; the save runs later (blur, document switch, quit, or 30 s).
    func setDraft(_ text: String, for path: String) {
        if drafts[path] == text { return }
        drafts[path] = text
        if text == (originals[path] ?? "") {
            statuses[path] = .saved
            saveTasks.removeValue(forKey: path)?.cancel()
        } else {
            statuses[path] = .dirty
            scheduleSave(path)
        }
    }

    /// Stage `text` and report whether a write is owed.
    func stage(_ text: String, for path: String) -> Bool {
        drafts[path] = text
        if text == (originals[path] ?? "") {
            statuses[path] = .saved
            return false
        }
        statuses[path] = .dirty
        return true
    }

    /// A freshly created note: its draft and baseline are the same empty body.
    func seed(_ path: String, body: String) {
        drafts[path] = body
        originals[path] = body
        statuses[path] = .saved
    }

    /// Write the staged draft now. Returns the save error, if any.
    @discardableResult
    func flush(_ path: String) async -> String? {
        saveTasks.removeValue(forKey: path)?.cancel()
        guard let text = drafts[path] else { return nil }
        let original = originals[path] ?? ""
        guard text != original else {
            if statuses[path] != .loading { statuses[path] = .saved }
            return nil
        }
        statuses[path] = .saving
        do {
            let raw = try await client.entryText(path: path)
            let patched = MarkdownBody.replace(in: raw, with: text)
            try await client.writeFile(path: path, text: patched)
            originals[path] = text
            statuses[path] = (drafts[path] == text) ? .saved : .dirty
            let preview = Self.preview(from: text)
            catalog.mutateEntries { entries in
                if let i = entries.firstIndex(where: { $0.path == path }) {
                    entries[i] = entries[i].with(preview: preview)
                }
            }
            // No eager rebuildIndexDerived/recomputeVisible/recomputeOpenDerived
            // here: the FSEvents pass triggered by this very write redoes all of
            // them moments later, and running the full index-wide recomputes on
            // every autosave is what made typing stutter (issue #87).
            print("[marple] saved inspector note \(path)")
            return nil
        } catch {
            statuses[path] = .failed("\(error)")
            print("[marple] save inspector note FAILED \(path): \(error)")
            return "\(error)"
        }
    }

    func flushAll() async {
        for path in Array(drafts.keys) { await flush(path) }
    }

    private func scheduleSave(_ path: String) {
        saveTasks[path]?.cancel()
        saveTasks[path] = Task { [weak self] in
            // Safety net only: the primary flush points are blur, doc switch,
            // and quit. Writing while the user types kicks off a full vault
            // reindex mid-IME-composition (issue #87), so keep this long.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush(path)
        }
    }

    private static func preview(from text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
}
