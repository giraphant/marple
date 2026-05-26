import Foundation

/// Strip Ulysses-bite damage from frontmatter list fields.
///
/// Markdown editors like Ulysses, Bear, and iA Writer corrupt YAML inline
/// flow arrays by interpreting `[a, b]` as a markdown link target and
/// auto-completing it to `[a, b](#)`. Downstream YAML parsers then fail.
///
/// Strips trailing `(...)` from `key: [...](...)` patterns on known
/// list-shaped top-level keys (`themes`, `author`, `authors`). Block-list
/// continuation lines are intentionally NOT sanitized: Ulysses doesn't bite
/// them (no inline brackets), and they're more likely to contain legitimate
/// human-authored content. The bite vector is exclusively single-line
/// flow-form values.
///
/// Two entry points:
/// - `sanitizeBody(_:)` — for already-extracted frontmatter content (no
///   `---` fences). Used by `YamlFrontmatter.parseMapping`.
/// - `sanitize(_:)` — for a full markdown file (with `---` fences). Used by
///   the `heal-frontmatter` sweep script.
public enum FrontmatterSanitizer {

    private static let listKeys: Set<String> = ["themes", "author", "authors"]

    /// Matches `[X](Y)` for any X without `]` and any Y without `)`. Capture
    /// group keeps the `[X]` part; the link tail is dropped.
    private static let damagePattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(\[[^\]]*\])\([^)]*\)"#)
    }()

    /// Sanitize an already-extracted frontmatter body (the content between
    /// `---` fences, fences removed). The body separation is the caller's
    /// guarantee — we never see markdown body content here.
    public static func sanitizeBody(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        var out = lines
        var changed = false
        for i in 0..<lines.count {
            let line = lines[i]
            guard
                let key = topLevelKey(of: line),
                listKeys.contains(key)
            else { continue }
            let stripped = stripDamage(line)
            if stripped != line {
                out[i] = stripped
                changed = true
            }
        }
        return changed ? out.joined(separator: "\n") : body
    }

    /// Sanitize a full markdown file with `---` fences. Frontmatter region
    /// is identified by the first `---` line and the next matching `---`;
    /// body content past the closing fence is returned byte-for-byte
    /// unchanged.
    public static func sanitize(_ raw: String) -> String {
        guard raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else { return raw }
        let lines = raw.components(separatedBy: "\n")
        var close: Int?
        // `.whitespacesAndNewlines` so CRLF (`---\r`) trims to `---` too.
        for i in 1..<lines.count
        where lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            close = i; break
        }
        guard let closeIdx = close else { return raw }

        let body = lines[1..<closeIdx].joined(separator: "\n")
        let sanitizedBody = sanitizeBody(body)
        guard sanitizedBody != body else { return raw }

        var out = lines
        out.replaceSubrange(1..<closeIdx, with: sanitizedBody.components(separatedBy: "\n"))
        return out.joined(separator: "\n")
    }

    /// Top-level key of a `key: value` line, or nil for indented /
    /// continuation / non-key lines.
    private static func topLevelKey(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let k = String(line[line.startIndex..<colon])
        guard !k.isEmpty, !k.hasPrefix(" "), !k.hasPrefix("\t") else { return nil }
        return k
    }

    /// Replace every `[X](Y)` occurrence with `[X]` on the line.
    private static func stripDamage(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return damagePattern.stringByReplacingMatches(
            in: line, range: range, withTemplate: "$1"
        )
    }
}
