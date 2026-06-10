import Foundation
import Darwin
import MarpleKit

// Unix domain socket listener that hosts the marple-cli wire protocol
// (QUA-107). Started by AppState after the AppModel is ready; lifetime is
// gated by the "允许 CLI 接入" setting so the listener exists only when the
// user has opted in.
//
// Wire format: one CLIRequest line in, one CLIResponse line out, close the
// connection. Each connection runs in its own detached task; the actual
// AppModel work happens via a @MainActor hop inside CLIHandlers so the GUI
// remains the single source of truth.

final class CLIServer: @unchecked Sendable {
    private let socketPath: String
    private let acceptQueue = DispatchQueue(label: "marple.cli.accept")
    private var listenerFD: Int32 = -1
    private var dispatchSource: DispatchSourceRead?
    // Captured once at start(); accessed only on @MainActor. Server isn't
    // restarted across vaults — boot rebuilds it each time.
    @MainActor private var model: AppModel?
    @MainActor private var indexer: VaultIndexer?

    init(socketPath: String = CLISocket.defaultPath()) {
        self.socketPath = socketPath
    }

    @MainActor
    func start(model: AppModel, indexer: VaultIndexer) throws {
        guard listenerFD < 0 else { return }
        self.model = model
        self.indexer = indexer

        // Make sure ~/Library/Application Support/Marple/ exists and any stale
        // socket from a prior crash is cleared (bind fails if the path exists).
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw CLIServerError.posix(op: "socket", errno: errno)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < cap else {
            close(fd)
            throw CLIServerError.pathTooLong(socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            let saved = errno
            close(fd)
            throw CLIServerError.posix(op: "bind", errno: saved)
        }
        // 0600: same user only. The socket already inherits user-only perms
        // from the directory's mode, but chmod nails it explicitly.
        _ = chmod(socketPath, 0o600)
        if listen(fd, 8) != 0 {
            let saved = errno
            close(fd)
            _ = unlink(socketPath)
            throw CLIServerError.posix(op: "listen", errno: saved)
        }
        listenerFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler(handler: Self.makeAcceptHandler(server: self, listenerFD: fd))
        source.setCancelHandler(handler: Self.makeCancelHandler(listenerFD: fd))
        source.resume()
        dispatchSource = source
        print("[marple] CLI server listening at \(socketPath)")
    }

    @MainActor
    func stop() {
        guard listenerFD >= 0 else { return }
        dispatchSource?.cancel()
        dispatchSource = nil
        // cancel handler closes fd
        listenerFD = -1
        _ = unlink(socketPath)
        model = nil
        indexer = nil
        print("[marple] CLI server stopped")
    }

    private static func makeAcceptHandler(server: CLIServer, listenerFD fd: Int32) -> @Sendable () -> Void {
        { [weak server] in server?.acceptOne(listenerFD: fd) }
    }

    private static func makeCancelHandler(listenerFD fd: Int32) -> @Sendable () -> Void {
        { close(fd) }
    }

    /// Accept one pending connection. Runs on `acceptQueue` (off main).
    private func acceptOne(listenerFD fd: Int32) {
        guard fd >= 0 else { return }
        let clientFD = accept(fd, nil, nil)
        if clientFD < 0 { return }
        // Apply a generous IO timeout so a stuck peer can't pin the worker.
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // QUA-208: a client that times out and closes before we write the
        // response must fail that write with EPIPE, not raise SIGPIPE — the
        // default disposition silently kills the whole app (exit 141).
        var noSigpipe: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) async {
        defer { close(clientFD) }
        guard let line = Self.readLine(fd: clientFD) else {
            _ = Self.writeResponse(fd: clientFD, response: .failure(code: CLIErrorCode.badRequest, message: "empty request"))
            return
        }
        let req: CLIRequest
        do {
            req = try JSONDecoder().decode(CLIRequest.self, from: line)
        } catch {
            _ = Self.writeResponse(fd: clientFD, response: .failure(code: CLIErrorCode.badRequest, message: "malformed request: \(error)"))
            return
        }
        let response = await dispatchOnMain(req)
        _ = Self.writeResponse(fd: clientFD, response: response)
    }

    @MainActor
    private func dispatchOnMain(_ req: CLIRequest) async -> CLIResponse {
        guard let model, let indexer else {
            return .failure(code: CLIErrorCode.internalError, message: "marple not ready")
        }
        return await CLIHandlers.handle(req, model: model, indexer: indexer)
    }

    // MARK: - blocking I/O helpers (run inside the per-connection task)

    private static func readLine(fd: Int32) -> Data? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { ptr -> ssize_t in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            buf.append(chunk, count: n)
            if buf.last == 0x0A {
                buf.removeLast()
                return buf
            }
            // Soft cap so a misbehaving peer can't OOM us. Requests are tiny.
            if buf.count > 1_000_000 { return nil }
        }
        return buf.isEmpty ? nil : buf
    }

    @discardableResult
    private static func writeResponse(fd: Int32, response: CLIResponse) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var bytes = try? encoder.encode(response) else { return false }
        bytes.append(0x0A)
        return bytes.withUnsafeBytes { buf -> Bool in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

enum CLIServerError: Error, CustomStringConvertible {
    case posix(op: String, errno: Int32)
    case pathTooLong(String)

    var description: String {
        switch self {
        case .posix(let op, let e):    return "\(op) failed: \(String(cString: strerror(e)))"
        case .pathTooLong(let p):      return "socket path too long: \(p)"
        }
    }
}
