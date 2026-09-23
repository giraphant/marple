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
        var moved: [ArchiveCollectionChange] = [], written: [Edit] = []
        var created: URL?
        do {
            // Recheck text before moving any directories. Writers that use our
            // lock cannot race; uncoordinated edits are checked again per write.
            for edit in planned.edits {
                let url = root.appendingPathComponent(edit.path)
                guard (try? Data(contentsOf: url)) == edit.before else { throw ArchiveCollectionError("conflict", "File changed: \(edit.path)") }
            }
            if command.action == "create" {
                let target = try checkedURL(Self.base + "/" + validateName(command.name))
                try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                created = target
            }
            for move in planned.result.moves {
                try FileManager.default.moveItem(at: try checkedURL(move.from), to: try checkedURL(move.to))
                moved.append(move)
            }
            for edit in planned.edits {
                let url = root.appendingPathComponent(ArchiveCollectionReferences.remap(edit.path, moves: moved))
                guard (try? Data(contentsOf: url)) == edit.before else { throw ArchiveCollectionError("conflict", "File changed: \(edit.path)") }
                try edit.after.write(to: url, options: .atomic)
                written.append(edit)
            }
            let result = ArchiveCollectionResult(inventory: try inventory(), moves: moved,
                updatedReferences: planned.result.updatedReferences, dryRun: false, requestID: command.requestID)
            journal.result = result
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            return result
        } catch {
            // Roll back only bytes still equal to our own write. Never erase an
            // external edit to make a failed operation appear transactional.
            var rollbackOK = true
            for edit in written.reversed() {
                let url = root.appendingPathComponent(ArchiveCollectionReferences.remap(edit.path, moves: moved))
                do {
                    guard try Data(contentsOf: url) == edit.after else { rollbackOK = false; continue }
                    if let before = edit.before { try before.write(to: url, options: .atomic) }
                    else { try FileManager.default.removeItem(at: url) }
                } catch { rollbackOK = false }
            }
            if rollbackOK {
                for move in moved.reversed() {
                    do { try FileManager.default.moveItem(at: try checkedURL(move.to), to: try checkedURL(move.from)) }
                    catch { rollbackOK = false; break }
                }
            }
            if rollbackOK, let created {
                do {
                    guard try FileManager.default.contentsOfDirectory(atPath: created.path).isEmpty else {
                        throw ArchiveCollectionError("conflict", "New collection received external files")
                    }
                    try FileManager.default.removeItem(at: created)
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
        guard inventory.issues.isEmpty else { throw ArchiveCollectionError("invalid_structure", inventory.issues.joined(separator: "\n")) }
        let fm = FileManager.default
        var moves: [ArchiveCollectionChange] = [], edits: [Edit] = []
        let groups = Set(inventory.collections.map(\.path))
        let members = Set(inventory.ungrouped + inventory.collections.flatMap(\.members))
        switch command.action {
        case "create":
            let name = try validateName(command.name)
            let target = Self.base + "/" + name
            try ensureAbsent(target)
            edits.append(.init(path: target + "/collection.md", before: nil, after: Data("# \(name)\n".utf8)))
        case "rename":
            guard command.paths.count == 1 else { throw ArchiveCollectionError("bad_request", "Rename requires one collection directory") }
            let source = relative(try checkedURL(command.paths[0]))
            guard groups.contains(source) else { throw ArchiveCollectionError("not_found", "Not a collection: \(source)") }
            let name = try validateName(command.name)
            let target = Self.base + "/" + name
            guard target != source else { throw ArchiveCollectionError("bad_request", "Collection already has this directory name") }
            try ensureAbsent(target)
            moves = [.init(from: source, to: target)]
        case "move":
            guard !command.paths.isEmpty, let destination = command.destination else { throw ArchiveCollectionError("bad_request", "Move requires Archive paths and a destination") }
            let dest = relative(try checkedURL(destination))
            guard dest == Self.base || groups.contains(dest) else { throw ArchiveCollectionError("not_found", "Destination is not a collection or archive root: \(dest)") }
            var sources = Set<String>(), destinations = Set<String>()
            for path in command.paths {
                var url = try checkedURL(path)
                if url.lastPathComponent == "archive.md" { url.deleteLastPathComponent() }
                let source = relative(url)
                guard members.contains(source + "/archive.md"), sources.insert(source).inserted else { throw ArchiveCollectionError("bad_request", "Not a unique Archive: \(path)") }
                let target = dest + "/" + url.lastPathComponent
                guard target != source else { continue }
                guard destinations.insert(target.lowercased()).inserted else { throw ArchiveCollectionError("name_conflict", "Duplicate destination: \(target)") }
                try ensureAbsent(target)
                moves.append(.init(from: source, to: target))
            }
        default: throw ArchiveCollectionError("bad_request", "Unknown collection action: \(command.action)")
        }
        if !moves.isEmpty {
            guard let walker = fm.enumerator(at: root.appendingPathComponent("vault"), includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw ArchiveCollectionError("not_found", "Vault missing") }
            for case let url as URL in walker {
                if url.lastPathComponent == "originals" || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { walker.skipDescendants(); continue }
                guard url.pathExtension == "md", regular(url) else { continue }
                let before = try Data(contentsOf: url)
                guard let text = String(data: before, encoding: .utf8) else { continue }
                let path = relative(url)
                var changed = ArchiveCollectionReferences.rewrite(text, at: path, moves: moves)
                if command.action == "rename", path == moves[0].from + "/collection.md" {
                    let regex = try! NSRegularExpression(pattern: #"(?m)^# [^\r\n]*"#)
                    if let match = regex.firstMatch(in: changed, range: NSRange(changed.startIndex..., in: changed)), let range = Range(match.range, in: changed) {
                        changed.replaceSubrange(range, with: "# " + (try validateName(command.name)))
                    } else { changed = "# \(try validateName(command.name))\n\n" + changed }
                }
                if changed != text { edits.append(.init(path: path, before: before, after: Data(changed.utf8))) }
            }
        }
        return (.init(inventory: inventory, moves: moves, updatedReferences: edits.map(\.path), dryRun: command.dryRun, requestID: command.requestID), edits)
    }

    private func ensureAbsent(_ path: String) throws {
        let url = try checkedURL(path)
        let parent = url.deletingLastPathComponent()
        if parent.path == baseURL.path && !FileManager.default.fileExists(atPath: parent.path) { return }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        guard !siblings.contains(where: { $0.compare(url.lastPathComponent, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw ArchiveCollectionError("name_conflict", "Destination exists: \(path)")
        }
    }
}
