// IndexBody.swift — body/preview/search-text helpers for the Swift indexer.
// Ports the following Rust functions from rust/reader-core/src/indexer.rs:
//   normalize_body_for_search (:1588-1595)
//   body_len (:199-200)
//   first_paragraph (:739-767) incl. is_kv_label (:828-838)
//   first_heading (:841-857)
//   search_text (:1597-1604)
// and isKVLabel (:828-838) is also exposed directly for use in IndexedEntry.

// MARK: - normalizeBodyForSearch

/// CRLF → LF, trim each line, drop blank lines, join with "\n".
/// Mirrors Rust `normalize_body_for_search` (:1588-1595).
public func normalizeBodyForSearch(_ body: String) -> String {
    body.replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

// MARK: - bodyLen

/// Unicode scalar count of the normalized body.
/// Mirrors Rust `body_len` (:199-200) which uses `.chars().count()` —
/// Swift equivalent is `.unicodeScalars.count`.
public func bodyLen(_ body: String) -> Int {
    normalizeBodyForSearch(body).unicodeScalars.count
}

// MARK: - isKVLabel

/// True for a bold "**label**：value" or "**label**: value" line
/// (full-width OR ASCII colon after the closing **).
/// Mirrors Rust `is_kv_label` (:828-838).
public func isKVLabel(_ line: String) -> Bool {
    guard line.hasPrefix("**") else { return false }
    let afterOpen = String(line.dropFirst(2))   // drop leading **
    guard let closeRange = afterOpen.range(of: "**") else { return false }
    // everything after the closing **
    var after = String(afterOpen[closeRange.upperBound...])
    // trim_start equivalent
    after = String(after.drop(while: { $0 == " " || $0 == "\t" }))
    return after.hasPrefix("：") || after.hasPrefix(":")
}

// MARK: - firstHeading

/// Returns the text of the first heading line (any level) with content.
/// A heading line must have one or more leading `#` chars followed by
/// whitespace; the returned string is the trimmed text after the `#`s.
/// Mirrors Rust `first_heading` (:841-857).
public func firstHeading(_ body: String) -> String? {
    for line in body.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard hashes > 0 else { continue }
        let rest = String(trimmed.dropFirst(hashes))
        // must start with whitespace after the hashes
        guard let firstChar = rest.first, firstChar.isWhitespace else { continue }
        let heading = rest.trimmingCharacters(in: .whitespaces)
        if !heading.isEmpty {
            return heading
        }
    }
    return nil
}

// MARK: - firstParagraph

/// Preview text for an entry, capped at 800 Unicode scalars.
/// Mirrors Rust `first_paragraph` (:739-767).
///
/// Rules (match exactly):
/// - Split normalized body (after CRLF→LF) on "\n\n".
/// - Skip empty paragraphs.
/// - Skip paragraphs starting with `#`.
/// - Skip paragraphs starting with `---`.
/// - Skip single `**...**` blocks whose total length < 80 (Rust uses `.len()`,
///   i.e. byte length; since Rust checks `trimmed.len() < 80` and the strings
///   here are ASCII-dominant bold labels, we use `.utf8.count` to match).
/// - Skip paragraphs whose FIRST line `isKVLabel`.
/// - For kept paragraphs, collapse internal whitespace (split on whitespace,
///   join " ") and append to output (with a leading " " if output non-empty).
/// - Accumulate until output reaches ≥ 800 Unicode scalars, then stop.
/// - Truncate to exactly 800 Unicode scalars.
public func firstParagraph(_ body: String) -> String {
    let maxChars = 800
    let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
    var out = ""
    for paragraph in normalized.components(separatedBy: "\n\n") {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        if trimmed.hasPrefix("#") { continue }
        if trimmed.hasPrefix("---") { continue }
        // Single **...** block with byte length < 80 → skip
        // Rust: trimmed.starts_with("**") && trimmed.ends_with("**") && trimmed.len() < 80
        if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") && trimmed.utf8.count < 80 {
            continue
        }
        // Skip if first line of paragraph isKVLabel
        let firstLine = trimmed
            .components(separatedBy: "\n")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            ?? ""
        if isKVLabel(firstLine) { continue }
        // Collapse whitespace: split on any whitespace, join " "
        let cleaned = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if !out.isEmpty {
            out.append(" ")
        }
        out.append(cleaned)
        if out.unicodeScalars.count >= maxChars {
            break
        }
    }
    // Truncate to 800 unicode scalars
    if out.unicodeScalars.count <= maxChars {
        return out
    }
    let endIndex = out.unicodeScalars.index(out.unicodeScalars.startIndex, offsetBy: maxChars)
    return String(out.unicodeScalars[..<endIndex])
}

// MARK: - searchText

/// For each part, collapse whitespace runs to single spaces, drop empty parts,
/// join non-empty parts with "\n".
/// Mirrors Rust `search_text` (:1597-1604).
public func searchText(_ parts: [String]) -> String {
    parts
        .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}
