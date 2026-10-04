import Foundation
import ArgumentParser
import MarpleKit

struct Collections: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage single-choice Archive collection metadata without moving files.",
        subcommands: [List.self, Create.self, Rename.self, Assign.self, Remove.self, Status.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List collections and ungrouped Archives as JSON.")
        func run() throws { try send(.init(action: "list")) }
    }
    struct Create: ParsableCommand {
        @Argument(help: "Collection field value.") var name: String
        @Option(name: .long, parsing: .upToNextOption, help: "Archive paths to group in the same operation.") var items: [String] = []
        @Flag(name: .long) var dryRun = false
        @Option(name: .long, help: "UUID for replay-safe requests; generated if absent.") var requestID: String?
        func run() throws { try send(.init(action: "create", paths: items, name: name, dryRun: dryRun, requestID: requestID)) }
    }
    struct Rename: ParsableCommand {
        @Argument(help: "Existing collection name.") var path: String
        @Argument(help: "New collection name (an existing name merges the groups).") var name: String
        @Flag(name: .long) var dryRun = false
        @Option(name: .long) var requestID: String?
        func run() throws { try send(.init(action: "rename", paths: [path], name: name, dryRun: dryRun, requestID: requestID)) }
    }
    struct Assign: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set collection for Archives; file paths stay unchanged.")
        @Argument(help: "Archive directories or archive.md paths; accepts multiple.") var paths: [String]
        @Option(name: .long, help: "Collection name, created on first use.") var to: String
        @Flag(name: .long) var dryRun = false
        @Option(name: .long) var requestID: String?
        func run() throws { try send(.init(action: "assign", paths: paths, name: to, dryRun: dryRun, requestID: requestID)) }
    }
    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Clear collection metadata; keep every Archive and its files.")
        @Argument var paths: [String]
        @Flag(name: .long) var dryRun = false
        @Option(name: .long) var requestID: String?
        func run() throws { try send(.init(action: "remove", paths: paths, dryRun: dryRun, requestID: requestID)) }
    }
    struct Status: ParsableCommand {
        @Argument(help: "Request UUID returned by a write or a timeout.") var requestID: String
        func run() throws { try send(.init(action: "status", requestID: requestID)) }
    }
    static func send(_ supplied: ArchiveCollectionCommand) throws {
        var command = supplied
        if !command.dryRun && !["list", "status"].contains(command.action) && command.requestID == nil {
            command.requestID = UUID().uuidString
        }
        let code: Int32
        do {
            let response = try CLITransport.roundTrip(.init(method: "collections", collection: command), timeoutSeconds: 60)
            code = emit(response.identified(by: command.requestID))
        } catch {
            let writes = !command.dryRun && !["list", "status"].contains(command.action)
            let message = writes ? "\(error). Inspect collections status \(command.requestID ?? "") before retrying a write." : String(describing: error)
            code = emit(CLIResponse.failure(code: writes ? "outcome_unknown" : "transport_error", message: message).identified(by: command.requestID))
        }
        if code != 0 { throw ExitCode(code) }
    }
}
