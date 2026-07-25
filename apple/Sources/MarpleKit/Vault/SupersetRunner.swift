import Foundation

#if os(macOS)
public struct SupersetInvocation: Sendable, Equatable {
    public let executablePath: String
    public let arguments: [String]
    /// Extra environment merged over the inherited one (MARPLE_* variables + PATH).
    public let environment: [String: String]

    public init(executablePath: String, arguments: [String], environment: [String: String] = [:]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }
}

public struct SupersetProcessResult: Sendable, Equatable {
    public let terminationStatus: Int32
    public let stdout: String
    public let stderr: String

    public init(terminationStatus: Int32, stdout: String, stderr: String) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct SupersetWorkspace: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let branch: String?
    public let projectName: String?
    public let hostName: String?
    public let type: String?

    public init(id: String, name: String?, branch: String?, projectName: String?, hostName: String?, type: String?) {
        self.id = id
        self.name = name
        self.branch = branch
        self.projectName = projectName
        self.hostName = hostName
        self.type = type
    }

    public var displayName: String {
        let title = [projectName, name]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " / ")
        var parts = [title.isEmpty ? id : title]
        if let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty, branch != name {
            parts.append("(\(branch))")
        }
        if let hostName = hostName?.trimmingCharacters(in: .whitespacesAndNewlines), !hostName.isEmpty {
            parts.append("· \(hostName)")
        }
        if let type = type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
            parts.append("· \(type)")
        }
        return parts.joined(separator: " ")
    }
}

public enum SupersetDispatchError: Error, Equatable, LocalizedError, Sendable {
    case missingWorkspaceID
    case missingAgent
    case missingCommandTemplate
    case launchFailed(String)
    case failed(status: Int32, stderr: String)

    public var friendlyMessage: String {
        switch self {
        case .missingWorkspaceID:
            return "请先在设置里填写 Superset workspace ID。"
        case .missingAgent:
            return "请先在设置里填写 Agent 命令。"
        case .missingCommandTemplate:
            return "请先在设置里填写分发命令模板。"
        case .launchFailed:
            return "无法启动分发命令，请检查设置。"
        case .failed:
            return "分发命令失败，请查看日志。"
        }
    }

    public var errorDescription: String? { friendlyMessage }
}

public enum SupersetWorkspaceListError: Error, Equatable, LocalizedError, Sendable {
    case missingCLIPath
    case launchFailed(String)
    case notAuthenticated
    case failed(status: Int32, stderr: String)

    public var friendlyMessage: String {
        switch self {
        case .missingCLIPath:
            return "请先填写 Superset CLI 路径。"
        case .launchFailed:
            return "无法启动 Superset CLI，请检查路径。"
        case .notAuthenticated:
            return "Superset 未登录，请先在终端运行 superset auth login。"
        case .failed:
            return "无法获取 Superset workspace，请查看日志。"
        }
    }

    public var errorDescription: String? { friendlyMessage }
}

public struct SupersetRunner: Sendable {
    public let execute: @Sendable (SupersetInvocation) async throws -> SupersetProcessResult
    public let log: @Sendable (String) -> Void

    public init(
        execute: @escaping @Sendable (SupersetInvocation) async throws -> SupersetProcessResult = SupersetRunner.defaultExecute,
        log: @escaping @Sendable (String) -> Void = { SupersetLog.shared.append($0) }
    ) {
        self.execute = execute
        self.log = log
    }

    public func dispatch(
        action: SupersetAction,
        config: SupersetDispatchConfig,
        context: SupersetDispatchContext
    ) async throws {
        let template = config.commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            throw SupersetDispatchError.missingCommandTemplate
        }

        let agent = config.agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty else {
            throw SupersetDispatchError.missingAgent
        }

        // Only templates that actually reference the workspace need one.
        let workspaceID = config.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if template.contains("MARPLE_WORKSPACE") {
            guard !workspaceID.isEmpty else {
                throw SupersetDispatchError.missingWorkspaceID
            }
        }

        // The package directory intentionally outlives this call: terminal
        // targets (`open -a …`, `orca terminal create`) return before the
        // agent reads prompt.md/context.md. It sits in the system temp dir,
        // which macOS cleans up on its own.
        let contextPackageURL = try SupersetContextPackageBuilder.write(action: action, context: context)
        let packageDirectory = contextPackageURL.deletingLastPathComponent()
        let prompt = SupersetPromptBuilder.prompt(
            action: action,
            targetRelativePath: context.targetPath,
            targetAbsolutePath: context.targetAbsolutePath,
            contextPackagePath: contextPackageURL.path,
            promptIntent: config.promptIntent(for: action)
        )
        let promptFileURL = packageDirectory.appendingPathComponent("prompt.md")
        try prompt.write(to: promptFileURL, atomically: true, encoding: .utf8)
        let runScriptURL = packageDirectory.appendingPathComponent("run.command")
        try Self.runScript(agent: agent, vaultRoot: context.workspaceRoot, promptFilePath: promptFileURL.path)
            .write(to: runScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runScriptURL.path)

        let invocation = Self.templateInvocation(
            template: template,
            environment: Self.dispatchEnvironment(
                agent: agent,
                workspaceID: workspaceID,
                cliPath: config.cliPath,
                vaultRoot: context.workspaceRoot,
                title: "\(action.label) · \((context.targetPath as NSString).lastPathComponent)",
                promptFilePath: promptFileURL.path,
                contextFilePath: contextPackageURL.path,
                runScriptPath: runScriptURL.path
            )
        )
        let result: SupersetProcessResult
        do {
            result = try await execute(invocation)
        } catch SupersetDispatchError.launchFailed(let message) {
            log("[\(action.rawValue)] \(context.targetPath) — 启动失败: \(message)")
            throw SupersetDispatchError.launchFailed(message)
        }
        guard result.terminationStatus == 0 else {
            log(Self.failureDetail(
                label: "[\(action.rawValue)] \(context.targetPath)",
                status: result.terminationStatus,
                stdout: result.stdout,
                stderr: result.stderr
            ))
            throw SupersetDispatchError.failed(status: result.terminationStatus, stderr: result.stderr)
        }
    }

    public func listWorkspaces(cliPath: String) async throws -> [SupersetWorkspace] {
        let trimmedCLIPath = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCLIPath.isEmpty else {
            throw SupersetWorkspaceListError.missingCLIPath
        }

        let invocation = Self.workspaceListInvocation(cliPath: Self.resolveCLIPath(trimmedCLIPath))
        let result: SupersetProcessResult
        do {
            result = try await execute(invocation)
        } catch SupersetDispatchError.launchFailed(let message) {
            log("[workspaces list] 启动失败: \(message)")
            throw SupersetWorkspaceListError.launchFailed(message)
        }
        guard result.terminationStatus == 0 else {
            // Not-authenticated has its own actionable message ("先登录"),
            // so it isn't logged as a failure; genuine failures are.
            if Self.isAuthFailure(stderr: result.stderr) {
                throw SupersetWorkspaceListError.notAuthenticated
            }
            log(Self.failureDetail(
                label: "[workspaces list]",
                status: result.terminationStatus,
                stdout: result.stdout,
                stderr: result.stderr
            ))
            throw SupersetWorkspaceListError.failed(status: result.terminationStatus, stderr: result.stderr)
        }
        return try Self.workspaces(from: result.stdout)
    }

    // Builds a single log entry carrying the exit code plus stderr (falling
    // back to stdout when stderr is empty, e.g. the CLI prints errors to
    // stdout) — the diagnostic the "请查看日志" hint promises.
    static func failureDetail(label: String, status: Int32, stdout: String, stderr: String) -> String {
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = trimmedStderr.isEmpty ? trimmedStdout : trimmedStderr
        let detail = output.isEmpty ? "(无输出)" : output
        return "\(label) — 退出码 \(status)\n\(detail)"
    }

    // Superset CLI phrases auth failures differently for OAuth ("not logged in")
    // and API-key ("Invalid API key.") sessions; treat both as not-authenticated.
    static func isAuthFailure(stderr: String) -> Bool {
        let markers = ["not logged in", "invalid api key", "unauthorized"]
        return markers.contains { stderr.localizedCaseInsensitiveContains($0) }
    }

    public func listWorkspaceIDs(cliPath: String) async throws -> [String] {
        try await listWorkspaces(cliPath: cliPath).map(\.id)
    }

    // Templates are user-authored zsh snippets; a login shell (-l) picks up the
    // user's own PATH additions on top of the explicit ones in the environment.
    public static func templateInvocation(template: String, environment: [String: String]) -> SupersetInvocation {
        SupersetInvocation(executablePath: "/bin/zsh", arguments: ["-lc", template], environment: environment)
    }

    static func dispatchEnvironment(
        agent: String,
        workspaceID: String,
        cliPath: String,
        vaultRoot: String,
        title: String,
        promptFilePath: String,
        contextFilePath: String,
        runScriptPath: String,
        basePATH: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> [String: String] {
        [
            "MARPLE_AGENT": agent,
            "MARPLE_WORKSPACE": workspaceID,
            // Resolved like the pre-template dispatch did, so a legacy 自定义
            // CLI 路径 (any basename) keeps working via the Superset preset.
            "MARPLE_SUPERSET_CLI": resolveCLIPath(cliPath),
            "MARPLE_VAULT_ROOT": vaultRoot,
            "MARPLE_TITLE": title,
            "MARPLE_PROMPT_FILE": promptFilePath,
            "MARPLE_CONTEXT_FILE": contextFilePath,
            "MARPLE_RUN_SCRIPT": runScriptPath,
            "PATH": [augmentedPATHPrefix(cliPath: cliPath), basePATH ?? "/usr/bin:/bin"].joined(separator: ":")
        ]
    }

    // GUI apps inherit a minimal PATH, so bare `superset` / `orca` / `claude`
    // would exit 127. Prepend the known install dirs; an absolute CLI path from
    // settings contributes its directory too.
    static func augmentedPATHPrefix(cliPath: String = "") -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = defaultSearchDirectories
        directories.append("\(home)/.local/bin")
        directories.append("/Applications/Orca.app/Contents/Resources/bin")
        if cliPath.contains("/") {
            directories.insert((cliPath as NSString).deletingLastPathComponent, at: 0)
        }
        return directories.joined(separator: ":")
    }

    /// The launcher terminal targets execute: cd into the vault, hand the
    /// prompt to the agent CLI. `.command` so Terminal/Otty open it directly.
    static func runScript(agent: String, vaultRoot: String, promptFilePath: String) -> String {
        // set -e: a launch can happen well after dispatch (open -a …), so a
        // vanished vault or prompt file must abort instead of running the
        // agent in the wrong directory or with an empty prompt.
        """
        #!/bin/zsh
        set -e
        export PATH=\(shellQuote(augmentedPATHPrefix())):"$PATH"
        cd \(shellQuote(vaultRoot))
        marple_prompt="$(cat \(shellQuote(promptFilePath)))"
        exec \(agent) "$marple_prompt"
        """
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func workspaceListInvocation(cliPath: String) -> SupersetInvocation {
        invocation(cliPath: cliPath, arguments: ["workspaces", "list", "--json", "--local"])
    }

    static func workspaces(from stdout: String) throws -> [SupersetWorkspace] {
        let data = Data(stdout.utf8)
        let workspaces = try JSONDecoder().decode([SupersetWorkspace].self, from: data)
        var seen = Set<String>()
        return workspaces.filter { seen.insert($0.id).inserted }
    }

    static func workspaceIDs(from stdout: String) -> [String] {
        var seen = Set<String>()
        return stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    // GUI-launched apps don't inherit the shell's PATH, so a bare `superset`
    // run via `/usr/bin/env` exits 127 ("not found") even when the CLI is
    // installed. Resolve a bare/empty command name against the known install
    // locations to an absolute path; only fall back to PATH lookup if nothing
    // matches. An explicit path (contains "/") is always respected as-is.
    static func resolveCLIPath(
        _ cliPath: String,
        searchDirectories: [String] = SupersetRunner.defaultSearchDirectories,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        guard !cliPath.contains("/") else { return cliPath }
        let name = cliPath.isEmpty ? "superset" : cliPath
        for directory in searchDirectories {
            let candidate = directory.hasSuffix("/") ? directory + name : directory + "/" + name
            if isExecutable(candidate) {
                return candidate
            }
        }
        return cliPath
    }

    static var defaultSearchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.superset/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    private static func invocation(cliPath: String, arguments: [String]) -> SupersetInvocation {
        if cliPath.contains("/") {
            return SupersetInvocation(executablePath: cliPath, arguments: arguments)
        } else {
            return SupersetInvocation(executablePath: "/usr/bin/env", arguments: [cliPath] + arguments)
        }
    }

    public static func defaultExecute(_ invocation: SupersetInvocation) async throws -> SupersetProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: invocation.executablePath)
            process.arguments = invocation.arguments
            if !invocation.environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(invocation.environment) { _, override in override }
            }

            let fileManager = FileManager.default
            let outputDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("marple-superset-output-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: outputDirectory) }

            let stdoutURL = outputDirectory.appendingPathComponent("stdout.txt")
            let stderrURL = outputDirectory.appendingPathComponent("stderr.txt")
            fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            fileManager.createFile(atPath: stderrURL.path, contents: nil)

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            do {
                try process.run()
            } catch {
                stdoutHandle.closeFile()
                stderrHandle.closeFile()
                throw SupersetDispatchError.launchFailed(error.localizedDescription)
            }

            process.waitUntilExit()
            stdoutHandle.closeFile()
            stderrHandle.closeFile()

            let stdoutData = try Data(contentsOf: stdoutURL)
            let stderrData = try Data(contentsOf: stderrURL)
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            return SupersetProcessResult(
                terminationStatus: process.terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        }.value
    }
}
#endif
