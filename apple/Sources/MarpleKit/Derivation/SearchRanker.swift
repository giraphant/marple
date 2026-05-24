import Foundation

/// In-memory, field-weighted entry ranker — a faithful port of the web reader's
/// `src/search.ts`. Powers the command palette's 快速 (metadata) mode: it scores
/// title/author/book/themes/topic/source/year/path/preview/identifier with the
/// same weights, boundary/exact-word boosts, phrase bonus, single-field bonus,
/// rating tiebreak, and ASCII fuzzy fallback the web uses. Native `Entry` only
/// models `doi` for the identifier field (the web also folds isbn/issn/…), so the
/// identifier text is doi-only here; everything else mirrors the web exactly.
public struct SearchField: Sendable {
    let name: String
    let text: String      // already normalized-for-tokenizing
    let weight: Double
    let fuzzy: Bool
}

public struct SearchDocument: Sendable {
    public let entry: Entry
    let fields: [SearchField]
}

private enum FieldWeight {
    static let title = 120.0
    static let author = 70.0
    static let book = 62.0
    static let themes = 56.0
    static let topic = 50.0
    static let source = 44.0
    static let year = 36.0
    static let path = 26.0
    static let preview = 18.0
    static let identifier = 10.0
}

public func buildSearchIndex(_ entries: [Entry]) -> [SearchDocument] {
    entries.map { SearchDocument(entry: $0, fields: entryFields($0)) }
}

/// Convenience used by tests; production builds the index once and reuses it.
public func searchEntries(_ entries: [Entry], _ query: String) -> [(entry: Entry, score: Double)] {
    searchDocuments(buildSearchIndex(entries), query)
}

public func searchDocuments(_ documents: [SearchDocument], _ query: String) -> [(entry: Entry, score: Double)] {
    let prepared = parseSearchQuery(query)
    if prepared.tokens.isEmpty { return [] }
    var out: [(entry: Entry, score: Double)] = []
    for doc in documents {
        let score = rankSearchDocument(doc, prepared)
        if score > 0 { out.append((doc.entry, score)) }
    }
    // Stable, deterministic order — tiebreak by path so the same query always
    // yields the same ranking (Swift's sort isn't stable; equal scores would
    // otherwise reorder run-to-run).
    out.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry.path < $1.entry.path }
    return out
}

// MARK: - Scoring

struct SearchPrepared {
    let phrase: String
    let tokens: [String]
}

func parseSearchQuery(_ query: String) -> SearchPrepared {
    let phrase = normalizeForTokenizing(query.trimmingCharacters(in: .whitespacesAndNewlines))
    let tokens = splitTokens(normalize(query))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .flatMap { token -> [String] in
            isIdentifierLike(token)
                ? [compactIdentifier(token)]
                : splitTokens(normalizeForTokenizing(token)).filter { !$0.isEmpty }
        }
        .filter { !$0.isEmpty }
    return SearchPrepared(phrase: phrase, tokens: tokens)
}

func rankSearchDocument(_ doc: SearchDocument, _ query: SearchPrepared) -> Double {
    if query.tokens.isEmpty { return 0 }
    var total = 0.0
    var matchedFieldNames = Set<String>()

    for token in query.tokens {
        let allowIdentifier = shouldSearchIdentifier(token)
        var best = 0.0
        var bestField = ""
        for field in doc.fields {
            if !shouldSearchField(token, field, allowIdentifier) { continue }
            let score = scoreTokenInField(token, field)
            if score > best { best = score; bestField = field.name }
        }
        if best <= 0 { return 0 }   // every token must match somewhere
        total += best
        if !bestField.isEmpty { matchedFieldNames.insert(bestField) }
    }

    total += scorePhrase(query.phrase, doc.fields)
    if matchedFieldNames.count == 1 { total += 18 }
    if total > 0 { total += doc.entry.ratingScore * 3 }
    return total
}

private func entryFields(_ entry: Entry) -> [SearchField] {
    let identifierText = (entry.doi ?? "").trimmingCharacters(in: .whitespaces)
    let raw: [(String, String, Double, Bool)] = [
        ("title", entry.title ?? "", FieldWeight.title, true),
        ("author", entry.author ?? "", FieldWeight.author, true),
        ("book", entry.book ?? "", FieldWeight.book, true),
        ("themes", entry.themes.joined(separator: " "), FieldWeight.themes, true),
        ("topic", entry.topic ?? "", FieldWeight.topic, true),
        ("source", entry.source ?? "", FieldWeight.source, true),
        ("year", entry.year ?? "", FieldWeight.year, false),
        ("path", entry.path, FieldWeight.path, false),
        ("preview", entry.preview, FieldWeight.preview, false),
        ("identifier", "\(identifierText) \(compactIdentifier(identifierText))", FieldWeight.identifier, false),
    ]
    return raw.map { SearchField(name: $0.0, text: normalizeForTokenizing($0.1), weight: $0.2, fuzzy: $0.3) }
}

private func scorePhrase(_ phrase: String, _ fields: [SearchField]) -> Double {
    if phrase.count < 3 || !phrase.contains(" ") { return 0 }
    var best = 0.0
    for field in fields {
        if field.name == "identifier" { continue }
        guard let idx = indexOf(normalize(field.text), phrase) else { continue }
        best = max(best, field.weight * 2 + positionBoost(idx))
    }
    return best
}

private func scoreTokenInField(_ token: String, _ field: SearchField) -> Double {
    let text = field.text
    if text.isEmpty { return 0 }
    if let idx = indexOf(text, token) {
        let boundary = isBoundaryHit(text, token, idx)
        let exactWord = boundary && isBoundaryAfter(text, idx + token.count)
        let factor = exactWord ? 4.0 : boundary ? 3.0 : 1.7
        return field.weight * factor + positionBoost(idx)
    }
    if !field.fuzzy || !canFuzzy(token) { return 0 }
    var best = 0.0
    for word in splitWords(text) {
        if !canCompareFuzzy(token, word) { continue }
        guard let distance = levenshteinWithin(token, word, fuzzyLimit(token)) else { continue }
        let factor = distance == 1 ? 1.2 : 0.85
        best = max(best, field.weight * factor)
    }
    return best
}

private func shouldSearchField(_ token: String, _ field: SearchField, _ allowIdentifier: Bool) -> Bool {
    if field.name == "identifier" { return allowIdentifier }
    if !isShortNumericToken(token) { return true }
    return field.name == "title" || field.name == "year"
}

private func shouldSearchIdentifier(_ token: String) -> Bool {
    if token.count >= 8 && token.contains(where: \.isNumber) { return true }
    if isDOIToken(token) { return true }
    if (token.contains("/") || token.contains(".")) && token.count >= 6 { return true }
    if hasIdentifierPrefix(token) { return true }
    return false
}

// MARK: - Token helpers (mirror search.ts regex behavior)

private func isShortNumericToken(_ token: String) -> Bool {
    !token.isEmpty && token.allSatisfy(\.isNumber) && token.count < 5
}

private func isIdentifierLike(_ token: String) -> Bool {
    if isDOIToken(token) { return true }
    if hasIdentifierPrefix(token) { return true }
    let hasDigit = token.contains(where: \.isNumber)
    let hasSep = token.contains("-") || token.contains("/") || token.contains(".")
    return hasDigit && hasSep && compactIdentifier(token).count >= 8
}

/// `^10\.\d{4,9}\/` — a DOI prefix.
private func isDOIToken(_ token: String) -> Bool {
    guard token.hasPrefix("10.") else { return false }
    let after = token.dropFirst(3)
    let digits = after.prefix { $0.isNumber }
    guard (4...9).contains(digits.count) else { return false }
    return after.dropFirst(digits.count).first == "/"
}

private func hasIdentifierPrefix(_ token: String) -> Bool {
    ["isbn", "doi", "issn", "pmid", "jstor"].contains { token.hasPrefix($0) }
}

private func compactIdentifier(_ s: String) -> String {
    String(normalize(s).unicodeScalars.filter { ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) }.map(Character.init))
}

private func canFuzzy(_ token: String) -> Bool {
    token.count >= 5 && isAsciiAlnum(token) && token.contains { ("a"..."z").contains($0) }
}

private func canCompareFuzzy(_ token: String, _ word: String) -> Bool {
    guard isAsciiAlnum(word) else { return false }
    return abs(token.count - word.count) <= fuzzyLimit(token)
}

private func fuzzyLimit(_ token: String) -> Int { token.count >= 8 ? 2 : 1 }

private func isAsciiAlnum(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
}

private func positionBoost(_ idx: Int) -> Double { Double(max(0, 35 - min(idx, 35))) }

// MARK: - Boundary checks (operate on character offsets)

private func isBoundaryHit(_ text: String, _ token: String, _ idx: Int) -> Bool {
    if idx == 0 { return true }
    if isBoundaryBefore(text, idx) { return true }
    // text.slice(idx-1, idx+token.length).includes(` ${token}`)
    let chars = Array(text)
    let lo = max(0, idx - 1)
    let hi = min(chars.count, idx + token.count)
    let slice = String(chars[lo..<hi])
    return slice.contains(" " + token)
}

private func isBoundaryBefore(_ text: String, _ idx: Int) -> Bool {
    if idx <= 0 { return true }
    let chars = Array(text)
    guard idx - 1 < chars.count else { return true }
    return !isAlnum(chars[idx - 1])
}

private func isBoundaryAfter(_ text: String, _ idx: Int) -> Bool {
    let chars = Array(text)
    if idx >= chars.count { return true }
    return !isAlnum(chars[idx])
}

private func isAlnum(_ c: Character) -> Bool {
    ("a"..."z").contains(c) || ("0"..."9").contains(c)
}

// MARK: - String utilities

/// First character offset of `needle` in `haystack`, or nil. Offset is a Character
/// index (mirrors JS UTF-16 indexing closely enough for BMP text like CJK/Latin).
private func indexOf(_ haystack: String, _ needle: String) -> Int? {
    guard !needle.isEmpty, let r = haystack.range(of: needle) else { return nil }
    return haystack.distance(from: haystack.startIndex, to: r.lowerBound)
}

/// normalize: lowercase → NFKD → strip combining marks (U+0300–U+036F).
func normalize(_ s: String) -> String {
    let decomposed = s.lowercased().decomposedStringWithCompatibilityMapping
    let scalars = decomposed.unicodeScalars.filter { !(0x0300...0x036F).contains($0.value) }
    return String(String.UnicodeScalarView(scalars))
}

/// normalizeForTokenizing: normalize then replace runs of `-`/`_` with a space.
func normalizeForTokenizing(_ s: String) -> String {
    var out = ""
    var prevWasSep = false
    for ch in normalize(s) {
        if ch == "-" || ch == "_" {
            if !prevWasSep { out.append(" ") }
            prevWasSep = true
        } else {
            out.append(ch)
            prevWasSep = false
        }
    }
    return out
}

/// TOKEN_SPLIT = /[\s,，;；]+/
private let tokenSeparators = Set<Character>([",", "，", ";", "；"])
private func splitTokens(_ s: String) -> [String] {
    s.split(whereSeparator: { $0.isWhitespace || tokenSeparators.contains($0) }).map(String.init)
}

/// WORD_SPLIT = /[\s,，;；:：/\\()[\]{}"'“”‘’|*]+/
private let wordSeparators = Set<Character>([
    ",", "，", ";", "；", ":", "：", "/", "\\", "(", ")", "[", "]", "{", "}",
    "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "|", "*",
])
private func splitWords(_ s: String) -> [String] {
    s.split(whereSeparator: { $0.isWhitespace || wordSeparators.contains($0) }).map(String.init)
}

/// Banded Levenshtein; returns nil when the distance exceeds `max`.
private func levenshteinWithin(_ a: String, _ b: String, _ max: Int) -> Int? {
    let ac = Array(a), bc = Array(b)
    if abs(ac.count - bc.count) > max { return nil }
    var prev = Array(0...bc.count)
    for i in 1...Swift.max(ac.count, 1) where !ac.isEmpty {
        var cur = [i]
        var rowMin = i
        for j in 1...Swift.max(bc.count, 1) where !bc.isEmpty {
            let cost = ac[i - 1] == bc[j - 1] ? 0 : 1
            let next = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            cur.append(next)
            rowMin = Swift.min(rowMin, next)
        }
        if rowMin > max { return nil }
        prev = cur
    }
    let distance = prev[bc.count]
    return distance <= max ? distance : nil
}
