import Foundation

public enum SidecarLaunch {
    /// Bind to port 0, read the OS-assigned port, release it. Small TOCTOU window
    /// is acceptable: the sidecar re-binds immediately on launch.
    public static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VaultError.backendUnavailable }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw VaultError.backendUnavailable }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    public static func arguments(repoRoot: String) -> [String] {
        ["run", "--release", "--manifest-path", "\(repoRoot)/rust/Cargo.toml",
         "-p", "reader-api"]
    }

    /// `MARPLE_ROOT` lets reader-api locate the repo; `VAULT_ROOT` overrides
    /// marple.config.json so the sidecar reads the user-picked workspace (see
    /// reader-core `resolve_workspace_root`).
    public static func environment(repoRoot: String, workspaceRoot: String,
                                   port: UInt16) -> [String: String] {
        ["MARPLE_ROOT": repoRoot, "VAULT_ROOT": workspaceRoot, "PORT": String(port)]
    }

    public static func baseURL(port: UInt16) -> URL {
        URL(string: "http://localhost:\(port)")!
    }
}

public final class SidecarProcess: @unchecked Sendable {
    private let repoRoot: String
    private let workspaceRoot: String
    private let cargoPath: String
    private var process: Process?
    public private(set) var baseURL: URL?

    public init(repoRoot: String, workspaceRoot: String, cargoPath: String = "/usr/bin/env") {
        self.repoRoot = repoRoot
        self.workspaceRoot = workspaceRoot
        self.cargoPath = cargoPath
    }

    /// Spawn reader-api and poll until /api/index answers (or time out).
    public func start(readinessTimeout: TimeInterval = 60) async throws -> URL {
        let port = try SidecarLaunch.freePort()
        let url = SidecarLaunch.baseURL(port: port)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cargoPath)
        // `/usr/bin/env cargo run …` resolves cargo from PATH.
        p.arguments = ["cargo"] + SidecarLaunch.arguments(repoRoot: repoRoot)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in SidecarLaunch.environment(repoRoot: repoRoot, workspaceRoot: workspaceRoot,
                                                port: port) { env[k] = v }
        p.environment = env
        try p.run()
        self.process = p
        self.baseURL = url

        let deadline = Date().addingTimeInterval(readinessTimeout)
        while Date() < deadline {
            if await probe(url) { return url }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        stop()
        throw VaultError.backendUnavailable
    }

    private func probe(_ url: URL) async -> Bool {
        var req = URLRequest(url: URL(string: url.absoluteString + "/api/index")!)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    deinit { stop() }
}
