import Yams

// MARK: - YamlValue

/// A structural YAML value.
///
/// Mirrors `serde_yaml::Value` as used in `indexer.rs`.
/// `.mapping([(String, YamlValue)])` preserves insertion order, matching
/// serde_yaml's `IndexMap` and Yams's ordered `Node.Mapping`.
public indirect enum YamlValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case sequence([YamlValue])
    case mapping([(String, YamlValue)])
}

// MARK: Equatable — tuples-in-array are NOT auto-synthesised

extension YamlValue: Equatable {
    public static func == (lhs: YamlValue, rhs: YamlValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case let (.bool(l), .bool(r)):
            return l == r
        case let (.int(l), .int(r)):
            return l == r
        case let (.double(l), .double(r)):
            return l == r
        case let (.string(l), .string(r)):
            return l == r
        case let (.sequence(l), .sequence(r)):
            return l == r
        case let (.mapping(l), .mapping(r)):
            guard l.count == r.count else { return false }
            for (lp, rp) in zip(l, r) {
                guard lp.0 == rp.0, lp.1 == rp.1 else { return false }
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - YamlFrontmatter

/// Parse raw frontmatter text (the content between `---` fences) into an
/// ordered top-level mapping.
///
/// Mirrors `parse_frontmatter` + `parse_lenient_mapping` in
/// `rust/reader-core/src/indexer.rs`.
public enum YamlFrontmatter {

    /// Parse the raw frontmatter string into an ordered top-level mapping.
    ///
    /// Primary path: Yams full parse → if result is a top-level mapping node,
    /// convert preserving insertion order.
    ///
    /// Fallback: if Yams throws OR the top-level node is not a mapping, run
    /// the lenient line parser ported verbatim from `parse_lenient_mapping`.
    ///
    /// Pre-parse: `FrontmatterSanitizer` strips Ulysses-bite damage
    /// (`themes: [a, b](#)` → `themes: [a, b]`) on the known list-shaped
    /// keys so existing damaged vault files still parse cleanly.
    ///
    /// Returns `[]` when there is no usable mapping.
    public static func parseMapping(_ raw: String) -> [(String, YamlValue)] {
        let sanitized = FrontmatterSanitizer.sanitizeBody(raw)
        if let pairs = tryYamsParse(sanitized) {
            return pairs
        }
        return parseLenientMapping(sanitized) ?? []
    }

    // MARK: - Primary path: Yams

    private static func tryYamsParse(_ raw: String) -> [(String, YamlValue)]? {
        // compose(yaml:) returns Node? and throws. `try?` flattens Optional<Optional<Node>>
        // to Optional<Node> in Swift 6, so we get Node? directly.
        guard let node = try? Yams.compose(yaml: raw) else { return nil }
        guard case .mapping(let mapping) = node else { return nil }
        var result: [(String, YamlValue)] = []
        result.reserveCapacity(mapping.count)
        for pair in mapping {
            // Keys in YAML mappings should be scalars in well-formed docs
            guard let keyStr = pair.key.scalar?.string else { continue }
            let value = convertNode(pair.value)
            result.append((keyStr, value))
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Convert Yams Node → YamlValue

    private static func convertNode(_ node: Yams.Node) -> YamlValue {
        switch node {
        case .scalar(let s):
            return convertScalar(s, resolvedNode: node)
        case .sequence(let seq):
            let values = seq.map { convertNode($0) }
            return .sequence(values)
        case .mapping(let map):
            var pairs: [(String, YamlValue)] = []
            for pair in map {
                guard let ks = pair.key.scalar?.string else { continue }
                pairs.append((ks, convertNode(pair.value)))
            }
            return .mapping(pairs)
        case .alias:
            return .null
        }
    }

    /// Convert a Yams scalar to the typed `YamlValue`, matching serde_yaml
    /// implicit-tag resolution behaviour.
    ///
    /// We use the high-level typed accessors on `Node` which already perform
    /// tag resolution (`node.bool`, `node.null`, `node.int`, `node.float`,
    /// `node.string`) rather than inspecting the internal `tag.name` directly
    /// (which is not public in Yams 5.x).
    private static func convertScalar(
        _ scalar: Yams.Node.Scalar,
        resolvedNode node: Yams.Node
    ) -> YamlValue {
        // null
        if node.null != nil { return .null }
        // bool
        if let b = node.bool { return .bool(b) }
        // int — prefer Int64; Yams exposes `int` as Int
        if let i = node.int { return .int(Int64(i)) }
        // float
        if let d = node.float { return .double(d) }
        // string fallback
        return .string(scalar.string)
    }

    // MARK: - Fallback: lenient line parser

    /// Port of `parse_lenient_mapping` from `indexer.rs:667-714`.
    ///
    /// Splits each line on the FIRST ASCII `:`. Uses `trim_end`-equivalent
    /// (preserving leading whitespace so that indented lines get a key that
    /// starts with whitespace and are therefore skipped). Accumulates `- item`
    /// lines under the most recent null-value key. Full-width `：` (U+FF1A) is
    /// not ASCII `:` and therefore not a split point.
    private static func parseLenientMapping(_ raw: String) -> [(String, YamlValue)]? {
        // Ordered storage: array preserves insertion order; dict for O(1) updates.
        var order: [String] = []
        var valueMap: [String: YamlValue] = [:]
        var currentSequenceKey: String? = nil

        for rawLine in raw.components(separatedBy: "\n") {
            // trim_end (Rust): strip trailing \r and whitespace from right only
            var line = rawLine
            while line.last == "\r" || line.last == " " || line.last == "\t" {
                line.removeLast()
            }
            // trim_start for prefix checks only (Rust: `let trimmed = line.trim_start()`)
            let trimmedStart = line.drop(while: { $0 == " " || $0 == "\t" })

            if trimmedStart.isEmpty || trimmedStart.hasPrefix("#") {
                continue
            }

            // "- item" → append to current sequence key
            if trimmedStart.hasPrefix("- ") {
                let item = String(trimmedStart.dropFirst(2))
                if let key = currentSequenceKey {
                    let scalar = parseLenientScalar(item)
                    if let existing = valueMap[key], case .sequence(let arr) = existing {
                        valueMap[key] = .sequence(arr + [scalar])
                    } else {
                        valueMap[key] = .sequence([scalar])
                    }
                }
                continue
            }

            // Split on first ASCII ':' — using `line` (trim_end equivalent, NOT trim_start)
            // Rust uses `line.split_once(':')` where `line = raw_line.trim_end()`
            guard let colonIdx = line.firstIndex(of: ":") else {
                currentSequenceKey = nil
                continue
            }

            let keyPart = String(line[line.startIndex..<colonIdx])
            let valueAfterColon = line[line.index(after: colonIdx)...]
            let valuePart = String(valueAfterColon)

            // If key starts with whitespace → skip (Rust: `key.starts_with(char::is_whitespace)`)
            if let first = keyPart.first, first.isWhitespace {
                currentSequenceKey = nil
                continue
            }

            let key = keyPart.trimmingCharacters(in: .whitespaces)
            let valueStr = valuePart.trimmingCharacters(in: .whitespaces)
            let parsedValue = parseLenientScalar(valueStr)

            // Record in order if new; update value
            if valueMap[key] == nil {
                order.append(key)
            }
            valueMap[key] = parsedValue

            // Track sequence key only when value is null (empty value → null)
            if case .null = parsedValue {
                currentSequenceKey = key
            } else {
                currentSequenceKey = nil
            }
        }

        let pairs = order.compactMap { k -> (String, YamlValue)? in
            guard let v = valueMap[k] else { return nil }
            return (k, v)
        }
        return pairs.isEmpty ? nil : pairs
    }

    // MARK: - parse_scalar (lenient path)

    /// Port of `parse_scalar` from `indexer.rs:716-721`.
    ///
    /// Empty string → `.null`; try full Yams parse of a single scalar token;
    /// on failure → `unquote(raw)` as a string.
    ///
    /// Note: if Yams parses the token as a top-level mapping (e.g. the value
    /// `"Dogs: A Study"` parses as `{Dogs: A Study}` in YAML), we fall through
    /// to `unquote` and return it as a plain string. This matches the lenient
    /// parser's intent: values on a line are scalars or sequences, never
    /// nested mappings (those would require multi-line indentation which the
    /// line-by-line parser handles separately).
    private static func parseLenientScalar(_ raw: String) -> YamlValue {
        if raw.isEmpty { return .null }
        // Try a full YAML parse of the single value token.
        // `try?` on a throwing function returning Node? flattens to Node? in Swift 6.
        if let node = try? Yams.compose(yaml: raw) {
            let converted = convertNode(node)
            // Reject mapping results — in line-value context a "Dogs: A Study"
            // style token is ambiguous YAML; treat it as a plain string instead.
            if case .mapping = converted {
                return .string(unquote(raw))
            }
            return converted
        }
        return .string(unquote(raw))
    }

    // MARK: - unquote

    /// Port of `unquote` from `indexer.rs:723-734`.
    ///
    /// Strip matching outer `"…"` or `'…'` quotes and unescape.
    private static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2 {
            if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
                let inner = String(trimmed.dropFirst().dropLast())
                return inner
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            if trimmed.hasPrefix("'") && trimmed.hasSuffix("'") {
                let inner = String(trimmed.dropFirst().dropLast())
                return inner.replacingOccurrences(of: "''", with: "'")
            }
        }
        return trimmed
    }
}
