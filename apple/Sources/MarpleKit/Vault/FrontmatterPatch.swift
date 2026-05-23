import Foundation

/// Surgical line-level frontmatter editor. Touches only the changed line within
/// the `---` fences; the body is returned byte-for-byte unchanged. No YAML
/// dependency — chosen to keep git diffs minimal (git is the backup/undo layer).
public enum FrontmatterPatch {

    private struct Parsed {
        var lines: [String]   // whole file split on "\n"
        var openIdx: Int      // index of opening "---" (always 0 when present)
        var closeIdx: Int     // index of closing "---"
    }

    private static func parse(_ raw: String) -> Parsed? {
        guard raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else { return nil }
        let lines = raw.components(separatedBy: "\n")
        var close: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            close = i; break
        }
        guard let c = close else { return nil }
        return Parsed(lines: lines, openIdx: 0, closeIdx: c)
    }

    private static func reassemble(_ p: Parsed) -> String {
        p.lines.joined(separator: "\n")
    }

    /// Top-level key of a frontmatter line ("year: 2019" → "year"); nil for
    /// indented/continuation lines or non-`key:` lines.
    private static func keyOf(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let k = String(line[line.startIndex..<colon])
        guard !k.isEmpty, !k.hasPrefix(" "), !k.hasPrefix("\t") else { return nil }
        return k
    }

    /// Render a scalar value, quoting+escaping when YAML would otherwise
    /// misread it (colon, comment marker, leading indicator, bool/null/number).
    static func yamlScalar(_ value: String) -> String {
        let first = value.first
        let needsQuote =
            value.isEmpty ||
            value.contains(": ") || value.hasSuffix(":") ||
            value.contains(" #") || value.hasPrefix("#") ||
            (first.map { " \t".contains($0) } ?? false) ||
            (value.last.map { " \t".contains($0) } ?? false) ||
            (first.map { "[]{}>|*&!%@`\"'-?,".contains($0) } ?? false) ||
            ["true", "false", "null", "yes", "no", "~"].contains(value.lowercased()) ||
            Double(value) != nil
        if !needsQuote { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func lineIndex(of key: String, in p: Parsed) -> Int? {
        guard p.closeIdx > p.openIdx + 1 else { return nil }
        for i in (p.openIdx + 1)..<p.closeIdx where keyOf(p.lines[i]) == key {
            return i
        }
        return nil
    }

    /// Set `key` to `value`: update in place, insert before the closing fence if
    /// absent, or remove the line when `value == nil`. No-op without frontmatter.
    /// `numeric: true` writes the value bare (for genuine number fields like year);
    /// otherwise it's treated as a string and quoted only when YAML requires it.
    public static func setScalar(_ raw: String, key: String, value: String?,
                                 numeric: Bool = false) -> String {
        guard var p = parse(raw) else { return raw }
        let found = lineIndex(of: key, in: p)
        func render(_ v: String) -> String { "\(key): \(numeric ? v : yamlScalar(v))" }
        switch (found, value) {
        case let (idx?, v?):
            p.lines[idx] = render(v)
        case let (idx?, .none):
            p.lines.remove(at: idx)
        case let (.none, v?):
            p.lines.insert(render(v), at: p.closeIdx)
        case (.none, .none):
            return raw
        }
        return reassemble(p)
    }

    /// Rewrite (or insert) `themes:` as a single flow array. Empty → "themes: []".
    public static func setThemes(_ raw: String, _ themes: [String]) -> String {
        guard var p = parse(raw) else { return raw }
        let rendered = themes.map(themeScalar).joined(separator: ", ")
        let line = "themes: [\(rendered)]"
        if let idx = lineIndex(of: "themes", in: p) {
            p.lines[idx] = line
        } else {
            p.lines.insert(line, at: p.closeIdx)
        }
        return reassemble(p)
    }

    // Flow-array element: quote when it contains a flow-breaking character.
    private static func themeScalar(_ v: String) -> String {
        let first = v.first
        let needsQuote =
            v.isEmpty ||
            v.contains(",") || v.contains("[") || v.contains("]") ||
            v.contains("{") || v.contains("}") ||
            v.contains(": ") || v.contains("\"") || v.contains("#") ||
            (first.map { " \t".contains($0) } ?? false) ||
            (v.last.map { " \t".contains($0) } ?? false)
        if !needsQuote { return v }
        let escaped = v
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
