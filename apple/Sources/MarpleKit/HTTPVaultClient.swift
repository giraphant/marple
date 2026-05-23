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

    public func search(_ query: SearchQuery) async throws -> [SearchHit] {
        var comps = URLComponents(string: baseURL.absoluteString + "/api/search")!
        var items = [URLQueryItem(name: "q", value: query.q),
                     URLQueryItem(name: "mode", value: "fast"),
                     URLQueryItem(name: "limit", value: String(query.limit))]
        if let t = query.type { items.append(URLQueryItem(name: "entry_type", value: t.rawValue)) }
        if let r = query.minRating { items.append(URLQueryItem(name: "min_rating", value: String(r))) }
        if let th = query.theme { items.append(URLQueryItem(name: "theme", value: th)) }
        comps.queryItems = items
        let data = try await run(URLRequest(url: comps.url!))
        struct Wrapper: Decodable { let items: [SearchHit] }
        do { return try JSONDecoder().decode(Wrapper.self, from: data).items }
        catch { throw VaultError.decode("\(error)") }
    }

    public func writeFile(path: String, text: String) async throws {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "PUT"
        req.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(text.utf8)
        _ = try await run(req)
    }

    public func openInEditor(path: String, app: String) async throws {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/api/open-in-editor")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["path": path, "app": app])
        _ = try await run(req)
    }

    public func createNote(path: String, text: String) async throws {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "POST"
        req.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(text.utf8)
        _ = try await run(req)
    }

    public func moveToTrash(path: String) async throws -> String {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        req.httpMethod = "DELETE"
        let data = try await run(req)
        struct Resp: Decodable { let trash: String? }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.trash ?? ""
    }

    public func listTrash() async throws -> [TrashItem] {
        let data = try await get("api/trash")
        struct Wrapper: Decodable { let items: [TrashItem] }
        do { return try JSONDecoder().decode(Wrapper.self, from: data).items }
        catch { throw VaultError.decode("\(error)") }
    }

    public func restoreTrash(name: String) async throws -> String {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/api/trash/" + enc + "/restore")!)
        req.httpMethod = "POST"
        let data = try await run(req)
        struct Resp: Decodable { let restored: String? }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.restored ?? ""
    }

    public func purgeTrash(name: String) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/api/trash/" + enc)!)
        req.httpMethod = "DELETE"
        _ = try await run(req)
    }
}
