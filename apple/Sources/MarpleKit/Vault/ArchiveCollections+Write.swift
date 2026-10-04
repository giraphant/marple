import Foundation
import Darwin

extension ArchiveCollections {
    private struct Edit: Codable {
        let path: String
        let before: Data?
        let after: Data
    }
    private struct Journal: Codable {
        let command: ArchiveCollectionCommand
        let moves: [ArchiveCollectionChange]
        let edits: [Edit]
        var result: ArchiveCollectionResult?
    }

    /// Called off the main actor. The process lock also defines the coordination
    /// point for Quasi. A durable pending journal blocks new writes after a crash.
    public func execute(_ command: ArchiveCollectionCommand) throws -> ArchiveCollectionResult {
        if command.action == "list" {
            return .init(inventory: try inventory(), moves: [], updatedReferences: [], dryRun: true, requestID: nil)
        }
        if command.action == "status" {
            let url = try journalURL(command.requestID)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ArchiveCollectionError("request_unknown", "No record for this request") }
            let record = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            guard var result = record.result else { throw ArchiveCollectionError("operation_incomplete", "Inspect recovery journal: \(url.path)") }
            result.replayed = true
            return result
        }
        if command.dryRun { return try plan(command).result }
        let directory = root.appendingPathComponent(".marple/collection-operations")
        try validateJournalDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = root.appendingPathComponent(".marple/archive-collections.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ArchiveCollectionError("locked", "Cannot open collection lock") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ArchiveCollectionError("busy", "Another collection/Archive writer is active") }
        defer { flock(fd, LOCK_UN) }
        let journalURL = try journalURL(command.requestID)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let record = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard record.command == command else { throw ArchiveCollectionError("request_conflict", "Request ID belongs to another operation") }
            guard var result = record.result else { throw ArchiveCollectionError("operation_incomplete", "Inspect recovery journal: \(journalURL.path)") }
            result.replayed = true
            return result
        }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard regular(file) else { throw ArchiveCollectionError("invalid_path", "Unsafe recovery journal") }
            let record = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
            guard record.result != nil else { throw ArchiveCollectionError("operation_incomplete", "Resolve pending operation before writing: \(file.path)") }
        }
        let planned = try plan(command)
        var journal = Journal(command: command, moves: planned.result.moves, edits: planned.edits, result: nil)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        var written: [Edit] = []
        do {
            // Recheck text before writing. Writers that use our
            // lock cannot race; uncoordinated edits are checked again per write.
            for edit in planned.edits {
                let url = root.appendingPathComponent(edit.path)
                guard (try? Data(contentsOf: url)) == edit.before else { throw ArchiveCollectionError("conflict", "File changed: \(edit.path)") }
            }
            for edit in planned.edits {
                let url = root.appendingPathComponent(edit.path)
                guard (try? Data(contentsOf: url)) == edit.before else { throw ArchiveCollectionError("conflict", "File changed: \(edit.path)") }
                try edit.after.write(to: url, options: .atomic)
                written.append(edit)
            }
            let result = ArchiveCollectionResult(inventory: try inventory(), moves: [],
                updatedReferences: planned.result.updatedReferences, dryRun: false, requestID: command.requestID)
            journal.result = result
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            return result
        } catch {
            // Roll back only bytes still equal to our own write. Never erase an
            // external edit to make a failed operation appear transactional.
            var rollbackOK = true
            for edit in written.reversed() {
                let url = root.appendingPathComponent(edit.path)
                do {
                    guard try Data(contentsOf: url) == edit.after else { rollbackOK = false; continue }
                    if let before = edit.before { try before.write(to: url, options: .atomic) }
                    else { try FileManager.default.removeItem(at: url) }
                } catch { rollbackOK = false }
            }
            if rollbackOK { try FileManager.default.removeItem(at: journalURL); throw error }
            throw ArchiveCollectionError("operation_incomplete", "\(error). Recovery journal: \(journalURL.path)")
        }
    }

    private func validateJournalDirectory() throws {
        let directory = root.appendingPathComponent(".marple/collection-operations")
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else {
            throw ArchiveCollectionError("invalid_path", "Recovery directory cannot contain symbolic links")
        }
    }

    private func journalURL(_ id: String?) throws -> URL {
        guard let id, let uuid = UUID(uuidString: id) else { throw ArchiveCollectionError("bad_request", "A mutation requires a UUID request ID") }
        try validateJournalDirectory()
        let url = root.appendingPathComponent(".marple/collection-operations/\(uuid.uuidString).json")
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ArchiveCollectionError("invalid_path", "Recovery journal cannot be a symbolic link")
        }
        return url
    }

    private func plan(_ command: ArchiveCollectionCommand) throws -> (result: ArchiveCollectionResult, edits: [Edit]) {
        let inventory = try inventory()
        let members = Set(inventory.ungrouped + inventory.collections.flatMap(\.members))
        let paths: [String]
        let value: String?
        switch command.action {
        case "create", "assign":
            value = try validateName(command.name ?? command.destination)
            paths = command.paths
        case "rename":
            guard command.paths.count == 1,
                  let group = inventory.collections.first(where: { $0.path == command.paths[0] }) else {
                throw ArchiveCollectionError("not_found", "Rename requires an existing collection name")
            }
            value = try validateName(command.name)
            paths = group.members
        case "remove":
            value = nil
            paths = command.paths
        case "move":
            // A previous client must never mistake a filesystem destination for
            // a new field value. New callers use assign/remove explicitly.
            throw ArchiveCollectionError("bad_request", "Directory collections have been replaced by collection fields; use assign or remove")
        default:
            throw ArchiveCollectionError("bad_request", "Unknown collection action: \(command.action)")
        }
        guard !paths.isEmpty else {
            throw ArchiveCollectionError("bad_request", "Choose at least one Archive; empty collections are not stored")
        }
        var edits: [Edit] = [], seen = Set<String>()
        for supplied in paths {
            var url = try checkedURL(supplied)
            if url.lastPathComponent != "archive.md" { url.appendPathComponent("archive.md") }
            let path = relative(url)
            guard members.contains(path), seen.insert(path).inserted else {
                throw ArchiveCollectionError("bad_request", "Not a unique Archive: \(supplied)")
            }
            let before = try Data(contentsOf: url)
            guard let raw = String(data: before, encoding: .utf8),
                  let frontmatter = Frontmatter.split(raw).frontmatter else {
                throw ArchiveCollectionError("invalid_metadata", "Archive needs YAML frontmatter: \(path)")
            }
            let pairs = YamlFrontmatter.parseMapping(frontmatter)
            guard pairs.filter({ $0.0 == "collection" }).count <= 1 else {
                throw ArchiveCollectionError("invalid_metadata", "Duplicate collection field: \(path)")
            }
            if let old = field(pairs, "collection") {
                switch old {
                case .string, .null: break
                default: throw ArchiveCollectionError("invalid_metadata", "collection must be a single text value: \(path)")
                }
            }
            let after = FrontmatterPatch.setCollection(raw, value: value)
            // Validate the surgical patch before any file in the batch is written.
            let parsed = YamlFrontmatter.parseMapping(Frontmatter.split(after).frontmatter ?? "")
            guard truthyText(parsed, "collection") == value else {
                throw ArchiveCollectionError("invalid_metadata", "Cannot update collection: \(path)")
            }
            if after != raw { edits.append(.init(path: path, before: before, after: Data(after.utf8))) }
        }
        return (.init(inventory: inventory, moves: [], updatedReferences: edits.map(\.path), dryRun: command.dryRun, requestID: command.requestID), edits)
    }
}
