import Foundation

/// Best-effort projection of one markdown SOURCE line to the plain text the reader
/// actually displays. Two reasons it matters: list match excerpts read as clean
/// prose, and counting matches over this projection keeps the list's match ordinal
/// aligned with the reader's rendered text (the renderer also drops these markers),
/// so a clicked list line lands on the right occurrence.
///
/// Mirrors the high-frequency transforms of `AttributedStringRenderer`: wikilinks →
/// label, leading block markers dropped, markdown links → text, inline
/// emphasis/code markers removed. NOT a full markdown engine — rare inline
/// constructs may survive; the reader jump tolerates that via its anchor + ordinal
/// fallback.
public enum MarkdownLine {
    public static func plainText(_ line: String) -> String {
        // 1. Wikilinks → visible label.
        let resolved = Wikilink.tokenize(line).map { token -> String in
            switch token {
            case .text(let t):                  return t
            case .wikilink(_, let label):       return label
            }
        }.joined()
        // 2. Drop a leading block marker (#, >, -/*/+, ordered "1.") + indentation.
        var s = stripLeadingMarker(resolved).cleaned
        // 3. Images then links: ![alt](url) → alt, [text](url) → text.
        s = replace(s, pattern: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")
        s = replace(s, pattern: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1")
        // 4. Inline code: keep content, drop backticks.
        s = s.replacingOccurrences(of: "`", with: "")
        // 5. Emphasis markers (multi-char first so "**" isn't seen as two "*").
        for marker in ["**", "__", "~~", "*", "_"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
