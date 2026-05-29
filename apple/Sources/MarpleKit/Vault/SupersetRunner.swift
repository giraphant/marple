import Foundation

public struct SupersetInvocation: Sendable, Equatable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
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
    case launchFailed(String)
    case failed(status: Int32, stderr: String)

    public var friendlyMessage: String {
        switch self {
        case .missingWorkspaceID:
            return "请先在设置里填写 Superset workspace ID。"
        case .missingAgent:
            return "请先在设置里填写 Superset agent。"
        case .launchFailed:
            return "无法启动 Superset CLI，请检查路径。"
        case .failed:
            return "Superset 调用失败，请查看日志。"
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

    public init(execute: @escaping @Sendable (SupersetInvocation) async throws -> SupersetProcessResult = SupersetRunner.defaultExecute) {
        self.execute = execute
    }

    public func dispatch(
        action: SupersetAction,
        config: SupersetDispatchConfig,
        context: SupersetDispatchContext
    ) async throws {
        let workspaceID = config.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.isEmpty else {
            throw SupersetDispatchError.missingWorkspaceID
        }

        let agent = config.agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty else {
            throw SupersetDispatchError.missingAgent
        }

        let trimmedConfig = SupersetDispatchConfig(
            workspaceID: workspaceID,
            agent: agent,
            cliPath: config.cliPath,
            reanalyzePrompt: config.reanalyzePrompt,
            formatPrompt: config.formatPrompt
        )
        let contextPackageURL = try SupersetContextPackageBuilder.write(action: action, context: context)
        defer { try? FileManager.default.removeItem(at: contextPackageURL.deletingLastPathComponent()) }
        let prompt = SupersetPromptBuilder.prompt(
            action: action,
            targetRelativePath: context.targetPath,
            targetAbsolutePath: context.targetAbsolutePath,
            contextPackagePath: contextPackageURL.path,
            promptIntent: trimmedConfig.promptIntent(for: action)
        )
        let invocation = Self.invocation(
            config: trimmedConfig,
            prompt: prompt,
            contextPackagePath: contextPackageURL.path
        )
        let result = try await execute(invocation)
        guard result.terminationStatus == 0 else {
            throw SupersetDispatchError.failed(status: result.terminationStatus, stderr: result.stderr)
        }
    }

    public func listWorkspaces(cliPath: String) async throws -> [SupersetWorkspace] {
        let trimmedCLIPath = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCLIPath.isEmpty else {
            throw SupersetWorkspaceListError.missingCLIPath
        }

        let invocation = Self.workspaceListInvocation(cliPath: trimmedCLIPath)
        let result: SupersetProcessResult
        do {
            result = try await execute(invocation)
        } catch SupersetDispatchError.launchFailed(let message) {
            throw SupersetWorkspaceListError.launchFailed(message)
        }
        guard result.terminationStatus == 0 else {
            if result.stderr.localizedCaseInsensitiveContains("not logged in") {
                throw SupersetWorkspaceListError.notAuthenticated
            }
            throw SupersetWorkspaceListError.failed(status: result.terminationStatus, stderr: result.stderr)
        }
        return try Self.workspaces(from: result.stdout)
    }

    public func listWorkspaceIDs(cliPath: String) async throws -> [String] {
        try await listWorkspaces(cliPath: cliPath).map(\.id)
    }

    public static func invocation(
        config: SupersetDispatchConfig,
        prompt: String,
        contextPackagePath: String
    ) -> SupersetInvocation {
        let runArguments = [
            "agents", "run",
            "--workspace", config.workspaceID,
            "--agent", config.agent,
            "--prompt", prompt,
            "--attachment", contextPackagePath
        ]

        return invocation(cliPath: config.cliPath, arguments: runArguments)
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
