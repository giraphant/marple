import Foundation

public enum MarkdownBody {
    public static func replace(in raw: String, with body: String) -> String {
        let normalized = normalize(body)
        guard let frontmatter = Frontmatter.split(raw).frontmatter else { return normalized }
        return "---\n\(frontmatter)\n---\n\n\(normalized)"
    }

    private static func normalize(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }
}
