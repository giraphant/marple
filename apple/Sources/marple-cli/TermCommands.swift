import ArgumentParser
import MarpleKit

struct Terms: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and maintain the running Marple terminology index.",
        subcommands: [Status.self, Lookup.self, Refresh.self])

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show terminology index counts and update time.")
        func run() throws {
            let code = runRequest(CLIRequest(method: CLIMethod.termsStatus), timeoutSeconds: 600)
            if code != 0 { throw ExitCode(code) }
        }
    }

    struct Lookup: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Look up direct counterparts and their document sources.")
        @Argument(help: "Chinese or English term.") var term: String
        func run() throws {
            let code = runRequest(CLIRequest(method: CLIMethod.termsLookup, query: term), timeoutSeconds: 600)
            if code != 0 { throw ExitCode(code) }
        }
    }

    struct Refresh: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Refresh terminology from changed documents.")
        @Flag(help: "Reparse all documents, retaining the previous index if rebuilding fails.") var rebuild = false
        func run() throws {
            let code = runRequest(CLIRequest(method: CLIMethod.termsRefresh, reset: rebuild), timeoutSeconds: 600)
            if code != 0 { throw ExitCode(code) }
        }
    }
}
