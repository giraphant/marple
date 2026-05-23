import Foundation

public enum Frontmatter {
    public static func split(_ raw: String) -> (frontmatter: String?, body: String) {
        guard raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else { return (nil, raw) }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // lines[0] == "---" (possibly with trailing \r). Find the next closing "---".
        var closing: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closing = i; break
        }
        guard let end = closing else { return (nil, raw) }
        let fm = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fm, body.trimmingCharacters(in: CharacterSet(charactersIn: "\n")))
    }
}
