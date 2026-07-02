import Foundation

public enum SemanticIndexDefaults {
    public static let modelID = "mlx-community/Qwen3-Embedding-8B-4bit-DWQ"
    public static let batchSize = 1
    public static let checkpointEvery = 64
    public static let textCap = 128_000
}

public enum SemanticDocumentBuilder {
    public static func docs(workspaceRoot: String, entries: [Entry], cap: Int = SemanticIndexDefaults.textCap) -> [SemanticDoc] {
        entries.map { doc(workspaceRoot: workspaceRoot, entry: $0, cap: cap) }
    }

    public static func doc(workspaceRoot: String, entry: Entry, cap: Int = SemanticIndexDefaults.textCap) -> SemanticDoc {
        SemanticDoc(path: entry.path, text: text(workspaceRoot: workspaceRoot, entry: entry, cap: cap))
    }

    /// Embeddable text for an entry: title + body with YAML frontmatter stripped.
    /// The embedder caps tokens at the model context length; this character cap only
    /// avoids tokenizing pathological inputs far beyond that window.
    public static func text(workspaceRoot: String, entry: Entry, cap: Int = SemanticIndexDefaults.textCap) -> String {
        let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(entry.path)
        var body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if body.hasPrefix("---") {
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            if let end = lines.dropFirst().firstIndex(where: { $0 == "---" }) {
                body = lines[(end + 1)...].joined(separator: "\n")
            }
        }
        let title = entry.title ?? ""
        let text = (title.isEmpty ? "" : title + "\n") + body
        return String(text.prefix(cap)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
