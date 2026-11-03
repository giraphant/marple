import Foundation

struct QuasiConfiguration: Decodable, Sendable {
    let store: String
    let service: String
    let keys: [Key]

    struct Key: Decodable, Identifiable, Sendable {
        let name: String
        let env: String
        let group: String
        let secret: Bool
        let description: String
        let set: Bool
        let source: String?
        let value: String?
        let choices: [String]?
        let `default`: String?

        var id: String { name }
        var displayedValue: String { secret ? "" : (value ?? (set ? nil : `default`) ?? "") }
    }
}

/// Quasi owns the Keychain items. Never put a configuration value in argv or
/// create an item with SecItem: reads by quasi's security CLI must retain access.
struct QuasiConfigClient: Sendable {
    let executablePath: String

    static func discoverPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        [".agents/skills/quasi/scripts/quasi", ".claude/skills/quasi/scripts/quasi", "Vibe/quasi/scripts/quasi"]
            .map { home.appendingPathComponent($0).path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    func show() async throws -> QuasiConfiguration {
        let data = try await run(arguments: ["config", "show", "--json"])
        do {
            return try JSONDecoder().decode(QuasiConfiguration.self, from: data)
        } catch {
            throw Failure.message(String(localized: "无法解析 Quasi 配置 JSON，请检查入口路径和 quasi 版本。"))
        }
    }

    func set(_ name: String, value: String) async throws {
        _ = try await run(arguments: ["config", "set", name], input: value + "\n")
    }

    func unset(_ name: String) async throws {
        _ = try await run(arguments: ["config", "unset", name])
    }

    private func run(arguments: [String], input: String? = nil) async throws -> Data {
        let path = (executablePath as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw Failure.message(String(localized: "找不到可执行的 Quasi 入口，请填写 scripts/quasi 的绝对路径。"))
        }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                throw Failure.message(String(localized: "无法启动 Quasi：\(error.localizedDescription)"))
            }
            // Drain both streams concurrently so diagnostics cannot fill a pipe
            // while we wait for stdout or process termination.
            let output = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
            let errors = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            var inputError: Error?
            do {
                if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
            } catch { inputError = error }
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            let data = await output.value
            let detail = String(decoding: await errors.value, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw Failure.message(detail.isEmpty
                    ? String(localized: "Quasi 命令失败（退出码 \(process.terminationStatus)）。") : detail)
            }
            if let inputError {
                throw Failure.message(String(localized: "无法向 Quasi 写入配置：\(inputError.localizedDescription)"))
            }
            return data
        }.value
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): message }
        }
    }
}
