import Foundation

public struct HTTPVaultClient: VaultClient {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private func get(_ path: String) async throws -> Data {
        // Use string concatenation instead of appendingPathComponent to avoid
        // percent-encoding slashes in paths like "vault/papers/x.md".
        let url = URL(string: baseURL.absoluteString + "/" + path)!
        return try await run(URLRequest(url: url))
    }

    private func run(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw VaultError.backendUnavailable }
        guard let http = response as? HTTPURLResponse else { throw VaultError.backendUnavailable }
        guard (200..<300).contains(http.statusCode) else {
            throw VaultError.http(status: http.statusCode,
                                  body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    public func index() async throws -> [Entry] {
        let data = try await get("api/index")
        struct Wrapper: Decodable { let items: [Entry] }
        do { return try JSONDecoder().decode(Wrapper.self, from: data).items }
        catch { throw VaultError.decode("\(error)") }
    }

    public func entryText(path: String) async throws -> String {
        let data = try await get(path)
        return String(decoding: data, as: UTF8.self)
    }

    public func openInEditor(path: String, app: String) async throws {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/api/open-in-editor")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["path": path, "app": app])
        _ = try await run(req)
    }
}
