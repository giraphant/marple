import Foundation
import ArgumentParser
import MarpleKit
#if canImport(Darwin)
import Darwin
#endif

// marple-cli — small AI-agent-facing remote control for Marple (QUA-107).
// The client never touches the vault directly; all work happens in Marple.app.

// MARK: - Socket transport

enum CLITransport {
    static func roundTrip(_ request: CLIRequest, socketPath: String = CLISocket.defaultPath(), timeoutSeconds: Double = 5.0) throws -> CLIResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw CLIClientError.cannotConnect(reason: "socket() failed: \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count >= sunPathCapacity {
            throw CLIClientError.cannotConnect(reason: "socket path too long: \(socketPath)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connectResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            throw CLIClientError.notRunning(reason: String(cString: strerror(errno)))
        }

        let encoder = JSONEncoder()
        var line = try encoder.encode(request)
        line.append(0x0A)
        try line.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                if n <= 0 { throw CLIClientError.transport(reason: "write: \(String(cString: strerror(errno)))") }
                sent += n
            }
        }

        var responseBuf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        readLoop: while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { throw CLIClientError.transport(reason: "read: \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            responseBuf.append(chunk, count: n)
            if responseBuf.last == 0x0A { break readLoop }
        }
        if responseBuf.isEmpty { throw CLIClientError.transport(reason: "empty response") }
        if responseBuf.last == 0x0A { responseBuf.removeLast() }
        return try JSONDecoder().decode(CLIResponse.self, from: responseBuf)
    }
}

enum CLIClientError: Error, CustomStringConvertible {
    case cannotConnect(reason: String)
    case notRunning(reason: String)
    case transport(reason: String)

    var description: String {
        switch self {
        case .cannotConnect(let r): return "cannot connect to marple: \(r)"
        case .notRunning(let r):    return "marple not running or CLI disabled: \(r)"
        case .transport(let r):     return "transport error: \(r)"
        }
    }

    var errorCode: String {
        switch self {
        case .notRunning: return CLIErrorCode.notRunning
        default: return CLIErrorCode.internalError
        }
    }
}

// MARK: - Output

func emit(_ response: CLIResponse) -> Int32 {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    if let bytes = try? encoder.encode(response) {
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    return response.ok ? 0 : 1
}

func emitError(code: String, message: String) -> Int32 {
    emit(CLIResponse.failure(code: code, message: message))
}

// QUA-208: methods that self-heal the index (search/open) run a synchronous
// reconcile in the app, and right after a cold launch that also queues behind
// the boot reconcile — well over the default 5s on a large vault. Give them
// a generous read timeout instead of giving up mid-request.
let reconcilingTimeout = 30.0

func runRequest(_ request: CLIRequest, timeoutSeconds: Double = 5.0) -> Int32 {
    do {
        let response = try CLITransport.roundTrip(request, timeoutSeconds: timeoutSeconds)
        return emit(response)
    } catch let e as CLIClientError {
        return emitError(code: e.errorCode, message: e.description)
    } catch {
        return emitError(code: CLIErrorCode.internalError, message: "\(error)")
    }
}

func runOpenWithFallback(_ path: String) -> Int32 {
    do {
        let response = try CLITransport.roundTrip(CLIRequest(method: CLIMethod.open, path: path),
                                                  timeoutSeconds: reconcilingTimeout)
        return emit(response)
    } catch CLIClientError.notRunning {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [marpleURL(path: path).absoluteString]
        do {
            try task.run()
            task.waitUntilExit()
            return emit(CLIResponse.success(CLIResponseData(opened: true)))
        } catch {
            return emitError(code: CLIErrorCode.internalError, message: "open URL failed: \(error)")
        }
    } catch let e as CLIClientError {
        return emitError(code: e.errorCode, message: e.description)
    } catch {
        return emitError(code: CLIErrorCode.internalError, message: "\(error)")
    }
}

func marpleURL(path: String) -> URL {
    var c = URLComponents()
    c.scheme = "marple"
    c.host = "open"
    c.queryItems = [URLQueryItem(name: "path", value: path)]
    return c.url!
}

// MARK: - Subcommands

struct MarpleCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "marple-cli",
        abstract: "Search, read, and open Marple documents from agent workflows.",
        subcommands: [Search.self, Read.self, Open.self, Ping.self]
    )
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Full-text search via the running Marple index.")
    @Argument(help: "Search query.")
    var query: String
    @Option(name: .long, help: "Max hits returned.")
    var limit: Int = 20

    func run() throws {
        let code = runRequest(CLIRequest(method: CLIMethod.search, query: query, limit: limit),
                              timeoutSeconds: reconcilingTimeout)
        if code != 0 { throw ExitCode(code) }
    }
}

struct Read: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read one document's frontmatter and body.")
    @Argument(help: "Vault-relative path of the document.")
    var path: String

    func run() throws {
        let code = runRequest(CLIRequest(method: CLIMethod.read, path: path))
        if code != 0 { throw ExitCode(code) }
    }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open a document in Marple's Pages workspace.")
    @Argument(help: "Vault-relative path of the document.")
    var path: String

    func run() throws {
        let code = runOpenWithFallback(path)
        if code != 0 { throw ExitCode(code) }
    }
}

struct Ping: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Probe whether Marple's CLI server is up.")
    func run() throws {
        let code = runRequest(CLIRequest(method: CLIMethod.ping))
        if code != 0 { throw ExitCode(code) }
    }
}

MarpleCLI.main()
