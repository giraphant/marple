import ArgumentParser
import Foundation
import MarpleKit

protocol OrganizationCommand: ParsableCommand {
    var request: CLIRequest { get }
}

extension OrganizationCommand {
    func run() throws {
        let code = runRequest(request)
        if code != 0 { throw ExitCode(code) }
    }
}

struct MutationOptions: ParsableArguments {
    @Option(name: .customLong("retry-request"), help: "Recover the original mutation using its request UUID; an unknown request is never executed again.")
    var retryRequest: String?

    func validate() throws {
        if let retryRequest, UUID(uuidString: retryRequest) == nil {
            throw ValidationError("--retry-request must be a UUID")
        }
    }
}

protocol OrganizationMutationCommand: ParsableCommand {
    var request: CLIRequest { get }
    var recovery: MutationOptions { get }
}

extension OrganizationMutationCommand {
    func run() throws {
        let code = runMutationRequest(request, retryRequest: recovery.retryRequest)
        if code != 0 { throw ExitCode(code) }
    }
}

struct MoveOptions: ParsableArguments {
    @Argument(help: "Full IDs from tabs list, in the desired order.")
    var ids: [String]
    @Option(name: .long, help: "Move into this folder, appending after its children.")
    var parent: String?
    @Option(name: .long, help: "Place before this tab or folder in its parent and section.")
    var before: String?
    @Option(name: .long, help: "Place after this tab or folder in its parent and section.")
    var after: String?
    @Flag(name: .long, help: "Append to the fixed pages section at the root.")
    var root = false

    func request(method: String) -> CLIRequest {
        CLIRequest(method: method, ids: ids, parent: parent, before: before, after: after, root: root)
    }
}

struct Tabs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and organize tabs in the current Space.",
        subcommands: [List.self, Rename.self, Move.self])

    struct List: OrganizationCommand {
        static let configuration = CommandConfiguration(
            abstract: "Return the sidebar tree, IDs, titles, paths, and pinned state as JSON.")
        var request: CLIRequest { CLIRequest(method: CLIMethod.tabsList) }
    }

    struct Rename: OrganizationMutationCommand {
        @OptionGroup var recovery: MutationOptions
        static let configuration = CommandConfiguration(abstract: "Rename a tab or reset its title.")
        @Argument(help: "Full tab ID from tabs list.")
        var id: String
        @Argument(help: "New display title; omit when using --reset.")
        var title: String?
        @Flag(name: .long, help: "Restore the document's default title.")
        var reset = false
        var request: CLIRequest { CLIRequest(method: CLIMethod.tabsRename, id: id, title: title, reset: reset) }
    }

    struct Move: OrganizationMutationCommand {
        @OptionGroup var recovery: MutationOptions
        static let configuration = CommandConfiguration(
            abstract: "Move tabs using exactly one of --parent, --root, --before, or --after.")
        @OptionGroup var options: MoveOptions
        var request: CLIRequest { options.request(method: CLIMethod.tabsMove) }
    }
}

struct Folders: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create and organize sidebar folders in the current Space.",
        subcommands: [Create.self, Rename.self, Move.self, Dissolve.self])

    struct Create: OrganizationMutationCommand {
        @OptionGroup var recovery: MutationOptions
        static let configuration = CommandConfiguration(
            abstract: "Create a folder, optionally grouping tabs and folders in the supplied order.")
        @Argument(help: "Folder name.")
        var title: String
        @Option(name: .long, help: "Create as a subfolder of this folder ID.")
        var parent: String?
        @Option(name: .long, parsing: .upToNextOption, help: "Tab and folder IDs to place inside; tabs become pinned.")
        var items: [String] = []
        var request: CLIRequest {
            CLIRequest(method: CLIMethod.foldersCreate, ids: items, title: title, parent: parent)
        }
    }

    struct Rename: OrganizationMutationCommand {
        @OptionGroup var recovery: MutationOptions
        static let configuration = CommandConfiguration(abstract: "Rename a sidebar folder.")
        @Argument(help: "Full folder ID from tabs list.")
        var id: String
        @Argument(help: "New folder name.")
        var title: String
        var request: CLIRequest { CLIRequest(method: CLIMethod.foldersRename, id: id, title: title) }
    }

    struct Move: OrganizationMutationCommand {
        @OptionGroup var recovery: MutationOptions
        static let configuration = CommandConfiguration(
            abstract: "Move folders using exactly one of --parent, --root, --before, or --after.")
        @OptionGroup var options: MoveOptions
        var request: CLIRequest { options.request(method: CLIMethod.foldersMove) }
    }

    struct Dissolve: OrganizationMutationCommand {
        @OptionGroup var recovery: MutationOptions
        static let configuration = CommandConfiguration(abstract: "Remove a folder, promoting its children in place.")
        @Argument(help: "Full folder ID from tabs list.")
        var id: String
        var request: CLIRequest { CLIRequest(method: CLIMethod.foldersDissolve, id: id) }
    }
}
