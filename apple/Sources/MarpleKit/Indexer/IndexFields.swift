// MARK: - IndexFields
//
// Free functions mirroring the field accessor and transform helpers in
// `rust/reader-core/src/indexer.rs`.  Every function is a direct port;
// comments cite the corresponding Rust line ranges.

// MARK: - field / truthyText  (:966-989)

/// Return the first value whose key exactly matches `name` (case-sensitive).
/// Mirrors `field` (:966-974).
public func field(_ map: [(String, YamlValue)], _ name: String) -> YamlValue? {
    map.first(where: { $0.0 == name })?.1
}

/// Return the textValue of `field(map, key)`, converting empty string to nil.
/// Mirrors `truthy_field_text` (:987-989).
public func truthyText(_ map: [(String, YamlValue)], _ key: String) -> String? {
    textValue(field(map, key)).flatMap { $0.isEmpty ? nil : $0 }
}

// MARK: - textValue  (:1086-1094)

/// Convert a YamlValue to a String representation.
///
/// - null  → nil
/// - string → self
/// - bool  → "true" / "false"
/// - int / double → decimal string
/// - sequence / mapping → compact JSON (no spaces)
///
/// Mirrors `text_value` (:1086-1094).
public func textValue(_ v: YamlValue?) -> String? {
    guard let v else { return nil }
    switch v {
    case .null:
        return nil
    case .string(let s):
        return s
    case .bool(let b):
        return b ? "true" : "false"
    case .int(let n):
        return String(n)
    case .double(let d):
        // Match Rust's `Number.to_string()` via serde_yaml, which omits trailing
        // zeros for whole numbers and keeps minimal decimal places otherwise.
        return formatDouble(d)
    case .sequence, .mapping:
        // For seq/mapping, yaml_to_json → serde_json::to_string — compact JSON.
        return fieldJSONCell(v)
    }
}

// MARK: - intValue  (:1096-1102)

/// Extract an integer from a YamlValue.
///
/// - Number → i64 (double truncated toward zero)
/// - String → parse as i64
/// - else    → nil
///
/// Mirrors `int_value` (:1096-1102).
public func intValue(_ v: YamlValue?) -> Int64? {
    guard let v else { return nil }
    switch v {
    case .int(let n):
        return n
    case .double(let d):
        return Int64(d)      // trunc() is the default for Double → Int conversion
    case .string(let s):
        return Int64(s)
    default:
        return nil
    }
}

// MARK: - themeArray  (:1104-1109)

/// Extract an array of text values from a sequence YamlValue.
/// Returns nil if the value is not a sequence.
/// Mirrors `theme_array` (:1104-1109).
public func themeArray(_ v: YamlValue?) -> [String]? {
    guard case .sequence(let items) = v else { return nil }
    return items.compactMap { textValue($0) }
}

// MARK: - stripWiki  (:901-922)

/// Strip Obsidian wiki-link syntax from a string.
///
/// `[[target|display]]` → `display` (trimmed)
/// `[[target]]`         → `target`
/// No brackets          → unchanged
///
/// Mirrors `strip_wiki` (:901-922).
public func stripWiki(_ s: String) -> String {
    var output = ""
    var rest = s[s.startIndex...]
    while let startRange = rest.range(of: "[[") {
        output += rest[..<startRange.lowerBound]
        let afterOpen = rest[startRange.upperBound...]
        guard let endRange = afterOpen.range(of: "]]") else {
            // No closing brackets — keep the rest as-is (matches Rust behaviour)
            output += rest[startRange.lowerBound...]
            return output
        }
        let inner = String(afterOpen[..<endRange.lowerBound])
        let display: String
        if let pipeIdx = inner.firstIndex(of: "|") {
            display = String(inner[inner.index(after: pipeIdx)...]).trimmingCharacters(in: .whitespaces)
        } else {
            display = inner.trimmingCharacters(in: .whitespaces)
        }
        output += display
        rest = afterOpen[endRange.upperBound...]
    }
    output += rest
    return output
}

// MARK: - parseAuthors

/// Parse an author frontmatter value into an array of names.
///
/// - nil / null   → `[]`
/// - sequence     → wiki-stripped non-empty text-value items
/// - scalar       → legacy joined-string form (`"A, B & C"`); split via
///                  `splitAuthors` for back-compat with vault files written
///                  before QUA-109
///
/// Replaces the older `flattenAuthor` (which joined back into a single string).
/// All consumers now work with `[String]` directly.
public func parseAuthors(_ v: YamlValue?) -> [String] {
    guard let v else { return [] }
    switch v {
    case .null:
        return []
    case .sequence(let items):
        return items
            .compactMap { textValue($0) }
            .map { stripWiki($0) }
            .filter { !$0.isEmpty }
    default:
        guard let s = textValue(v) else { return [] }
        return splitAuthors(stripWiki(s))
    }
}

// MARK: - canonicalType  (QUA-119)

/// Recognize a raw `type` field value as one of the eight canonical Quasi
/// schema short forms, or reject it.
///
/// - "" and "A" → nil (sentinel "skip entry" values from the legacy pipeline)
/// - one of `paper / book / chapter / author / topic / journal / note / image`
///   → the same string
/// - anything else (including pre-QUA-119 long forms like `paper-analysis` /
///   `book-overview` and the older free-text aliases like `monograph` /
///   `reading-list` / `concept-note`) → nil, so `buildIndexedEntry` returns
///   `.skippedUnknownType` and the entry is reported (not silently normalized
///   into a familiar bucket).
///
/// The vault is the source of truth — Marple no longer compensates for stale
/// frontmatter. See feedback-align-marple-to-quasi-schema memory for context.
public func canonicalType(_ raw: String) -> String? {
    switch raw {
    case "paper", "book", "chapter", "author",
         "topic", "journal", "note", "image":
        return raw
    default:
        return nil
    }
}

// MARK: - ratingScore  (:886-899)

/// Extract a numeric rating from a YamlValue.
///
/// - Number → Double
/// - String → count of ★ chars; if none, parse as Double; else 0
/// - absent / other → 0
///
/// Mirrors `rating_score` (:886-899).
public func ratingScore(_ v: YamlValue?) -> Double {
    guard let v else { return 0.0 }
    switch v {
    case .int(let n):
        return Double(n)
    case .double(let d):
        return d
    case .string(let s):
        let stars = s.unicodeScalars.filter { $0 == "★" }.count
        if stars > 0 { return Double(stars) }
        return Double(s) ?? 0.0
    default:
        return 0.0
    }
}

// MARK: - JSON serialization helpers

/// Serialize a YamlValue to a compact JSON string.
/// Returns nil for `.null`.
/// Mirrors `yaml_to_json` + `json_cell` (:1065-1113).
public func fieldJSONCell(_ v: YamlValue?) -> String? {
    guard let v else { return nil }
    guard case .null = v else {
        return yamlToCompactJSON(v)
    }
    return nil
}

/// Like `fieldJSONCell` but also returns nil for falsy values
/// (false, 0, empty string).
/// Mirrors `truthy_json` (:1069-1084).
public func truthyJSONCell(_ v: YamlValue?) -> String? {
    guard let v else { return nil }
    switch v {
    case .null:
        return nil
    case .bool(false):
        return nil
    case .int(let n) where n == 0:
        return nil
    case .double(let d) where d == 0.0:
        return nil
    case .string(let s) where s.isEmpty:
        return nil
    default:
        return yamlToCompactJSON(v)
    }
}

// MARK: - Private: compact JSON serializer

/// Serialize a YamlValue to a compact JSON string (no spaces), matching
/// serde_json::to_string output format.
///
/// Returns nil only when the value is .null (callers handle that check).
private func yamlToCompactJSON(_ v: YamlValue) -> String? {
    switch v {
    case .null:
        return nil
    case .bool(let b):
        return b ? "true" : "false"
    case .int(let n):
        return String(n)
    case .double(let d):
        return formatDouble(d)
    case .string(let s):
        return jsonEncodeString(s)
    case .sequence(let items):
        let parts = items.compactMap { item -> String? in
            switch item {
            case .null: return "null"
            default: return yamlToCompactJSON(item)
            }
        }
        return "[" + parts.joined(separator: ",") + "]"
    case .mapping(let pairs):
        let parts = pairs.compactMap { (key, val) -> String? in
            let k = jsonEncodeString(key)
            guard let encoded: String = {
                switch val {
                case .null: return "null"
                default: return yamlToCompactJSON(val)
                }
            }() else { return nil }
            return k + ":" + encoded
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

/// Encode a Swift String as a JSON string literal (with surrounding quotes
/// and minimal escaping matching serde_json).
private func jsonEncodeString(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch.value {
        case 0x22: out += "\\\""   // "
        case 0x5C: out += "\\\\"  // \
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0x00...0x1F:
            out += String(format: "\\u%04x", ch.value)
        default:
            // Non-ASCII scalars — serde_json outputs UTF-8 without escaping them
            out.unicodeScalars.append(ch)
        }
    }
    out += "\""
    return out
}

/// Format a Double in the same compact style as serde_yaml's `Number.to_string()`
/// and serde_json's number serialiser.
///
/// Whole-number doubles (e.g. 4.0) are printed as "4.0" by serde_yaml's Display
/// (via the `yaml-rust` crate) but as "4.0" in JSON too — however in practice the
/// numbers that arrive here from serde_yaml parse as f64 only when they have a
/// fractional part; integer YAML values come through as i64 in our Swift YamlValue.
/// So we just need to format the Double faithfully without unnecessary trailing zeros
/// while still distinguishing it from an integer.
private func formatDouble(_ d: Double) -> String {
    // Match Rust behaviour: use minimal decimal representation.
    // Swift's String(d) already gives a minimal representation similar to Rust's
    // default Display for f64 (e.g. 3.5 → "3.5", 4.0 → "4").
    // However Swift may print "4.0" for whole-number doubles while Rust prints "4.0"
    // as well via serde_yaml. We keep Swift's default here.
    if d.isNaN { return "null" }
    if d.isInfinite { return d > 0 ? "null" : "null" }  // JSON has no infinity
    // Swift's default: "3.5", "4.0", etc.
    let s = String(d)
    return s
}
