import Foundation

/// Citation rendering — a faithful port of the web `citation.ts` so native and
/// web produce identical strings. Pure functions over an `Entry`.
public enum CitationFormat: String, Sendable, CaseIterable, Codable {
    case inlineEN = "inline-en"
    case inlineZH = "inline-zh"
    case title
    case markdown

    public var label: String {
        switch self {
        case .inlineEN: return "夹注 (英文)"
        case .inlineZH: return "夹注 (中文)"
        case .title:    return "标题"
        case .markdown: return "文献目录"
        }
    }

    public var example: String {
        switch self {
        case .inlineEN: return "(Clark, 1998)"
        case .inlineZH: return "（Clark，1998）"
        case .title:    return "Being There"
        case .markdown: return "Clark (1998). *Being There*. MIT Press."
        }
    }
}

// `splitAuthors` (comma / ` & ` / ` and `) already lives in RelationsIndex.swift.

/// Extract a surname from one author string — mirrors web `lastname`:
/// "Last, First" → "Last"; pure CJK → as-is; "First M. Last" → "Last".
func lastname(_ raw: String) -> String {
    let name = raw.trimmingCharacters(in: .whitespaces)
    if name.isEmpty { return "" }
    if name.contains(",") {
        return name.split(separator: ",", omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
    if isAllCJK(name) { return name }
    let parts = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return parts.last ?? name
}

/// True when every scalar is CJK ideograph / Hiragana / Katakana (web regex
/// `/^[一-鿿぀-ゟ゠-ヿ]+$/`).
func isAllCJK(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    return s.unicodeScalars.allSatisfy { sc in
        (0x4E00...0x9FFF).contains(sc.value) ||  // CJK Unified Ideographs
        (0x3040...0x309F).contains(sc.value) ||  // Hiragana
        (0x30A0...0x30FF).contains(sc.value)     // Katakana
    }
}

enum InlineStyle { case en, zh }

/// "Author / A & B / A et al." (zh: "A、B / A 等") for inline use.
/// Takes the parsed authors list directly (QUA-109 — no scalar splitting needed).
func authorsInline(_ authors: [String], style: InlineStyle) -> String {
    let list = authors.map(lastname).filter { !$0.isEmpty }
    if list.isEmpty { return "" }
    if list.count == 1 { return list[0] }
    if list.count == 2 {
        return style == .zh ? "\(list[0])、\(list[1])" : "\(list[0]) & \(list[1])"
    }
    return style == .zh ? "\(list[0]) 等" : "\(list[0]) et al."
}

/// Render `entry` as a citation string per `format`. Returns "" when the required
/// fields are missing (callers decide whether to surface that).
public func buildCitation(_ entry: Entry, format: CitationFormat) -> String {
    let authors = entry.author.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let year = entry.year?.trimmingCharacters(in: .whitespaces) ?? ""
    let title = entry.title?.trimmingCharacters(in: .whitespaces) ?? ""
    let source = entry.source?.trimmingCharacters(in: .whitespaces) ?? ""
    let doi = entry.doi?.trimmingCharacters(in: .whitespaces) ?? ""

    switch format {
    case .inlineEN:
        let a = authorsInline(authors, style: .en)
        if a.isEmpty && year.isEmpty { return "" }
        if !a.isEmpty && !year.isEmpty { return "(\(a), \(year))" }
        if !a.isEmpty { return "(\(a))" }
        return "(\(year))"
    case .inlineZH:
        let a = authorsInline(authors, style: .zh)
        if a.isEmpty && year.isEmpty { return "" }
        if !a.isEmpty && !year.isEmpty { return "（\(a)，\(year)）" }
        if !a.isEmpty { return "（\(a)）" }
        return "（\(year)）"
    case .title:
        return title
    case .markdown:
        let authorJoined = authors.joined(separator: ", ")
        var parts: [String] = []
        if !authorJoined.isEmpty && !year.isEmpty { parts.append("\(authorJoined) (\(year)).") }
        else if !authorJoined.isEmpty { parts.append("\(authorJoined).") }
        else if !year.isEmpty { parts.append("(\(year)).") }
        if !title.isEmpty { parts.append("*\(title)*.") }
        if !source.isEmpty { parts.append("\(source).") }
        if !doi.isEmpty { parts.append("https://doi.org/\(doi)") }
        return parts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
