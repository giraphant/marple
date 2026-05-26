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
        // `.whitespacesAndNewlines` so CRLF (`---\r`) trims to `---` too.
        for i in 1..<lines.count
        where lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
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

    /// Rewrite (or insert) `themes:` as a YAML block list (SPEC §5.2).
    /// Empty values remove the field entirely. Convenience wrapper over
    /// `setSequence` — kept for back-compat with older call sites.
    public static func setThemes(_ raw: String, _ themes: [String]) -> String {
        setSequence(raw, key: "themes", values: themes)
    }

    /// Rewrite (or insert) `key:` as a YAML block list. Empty values remove
    /// the field entirely (and any block-list continuation lines).
    ///
    /// Output shape (per SPEC §5.2 — Ulysses-safe):
    /// ```
    /// key:
    ///   - value1
    ///   - value2
    /// ```
    ///
    /// When `values` is empty: the existing `key:` line plus any immediately
    /// following block-list continuation lines (`  - item`) are removed.
    /// Rationale: empty list ≠ absent field in YAML; SPEC chooses absent.
    public static func setSequence(_ raw: String, key: String, values: [String]) -> String {
        guard var p = parse(raw) else { return raw }
        let existing = lineIndex(of: key, in: p)
        let replacement: [String]
        if values.isEmpty {
            replacement = []
        } else {
            replacement = ["\(key):"] + values.map { "  - \(sequenceScalar($0))" }
        }

        if let idx = existing {
            let end = scanSequenceContinuation(p.lines, from: idx)
            p.lines.replaceSubrange(idx..<end, with: replacement)
        } else if !replacement.isEmpty {
            p.lines.insert(contentsOf: replacement, at: p.closeIdx)
        }
        return reassemble(p)
    }

    /// Remove `key:` and any block-list continuation lines below it. No-op
    /// if the key is absent. Equivalent to `setSequence(..., values: [])` —
    /// also clears legacy scalar values written as `key: value` on one line.
    public static func removeKey(_ raw: String, key: String) -> String {
        setSequence(raw, key: key, values: [])
    }

    /// Scan forward from `start` (a `key:` line) to the index *past* the last
    /// block-list continuation line. Recognises any indent before `-` and
    /// rejects the `---` frontmatter fence (`-` not followed by EOL/whitespace).
    private static func scanSequenceContinuation(_ lines: [String], from start: Int) -> Int {
        var end = start + 1
        while end < lines.count, isBlockListItem(lines[end]) {
            end += 1
        }
        return end
    }

    private static func isBlockListItem(_ line: String) -> Bool {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == "-" else { return false }
        let after = line.index(after: idx)
        if after == line.endIndex { return true }      // lone "-" (null item)
        let next = line[after]
        return next == " " || next == "\t"             // "- value" — rejects "---"
    }

    /// Quote a scalar emitted as a YAML sequence item (block or flow). The
    /// rule is intentionally over-aggressive: any flow-indicator or
    /// block-indicator character forces quoting. Cheaper than a YAML
    /// round-trip gate and safe at both block- and flow-item positions.
    static func sequenceScalar(_ v: String) -> String {
        let first = v.first
        let needsQuote =
            v.isEmpty ||
            v.contains(",") || v.contains("[") || v.contains("]") ||
            v.contains("{") || v.contains("}") ||
            v.contains(": ") || v.hasSuffix(":") ||
            v.contains("\"") || v.contains("#") ||
            (first.map { "-?*&!%@`|>".contains($0) } ?? false) ||
            (first.map { " \t".contains($0) } ?? false) ||
            (v.last.map { " \t".contains($0) } ?? false) ||
            ["true", "false", "null", "yes", "no", "~"].contains(v.lowercased()) ||
            Double(v) != nil
        if !needsQuote { return v }
        let escaped = v
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
