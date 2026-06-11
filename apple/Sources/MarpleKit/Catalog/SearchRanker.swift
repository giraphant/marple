import Foundation
import Darwin

/// In-memory, field-weighted entry ranker — port of the web reader's
/// `src/search.ts`. Powers the command palette's 快速 (metadata) mode: it scores
/// title/author/book/themes/topics/source/year/path/preview/identifier with the
/// same weights, boundary/exact-word boosts, phrase bonus, single-field bonus,
/// rating tiebreak, and ASCII fuzzy fallback the web uses.
///
/// Performance design (QUA-96): all field text is stored as **normalized UTF-8
/// bytes** (no per-call `Array(text)` reallocation, no `String.distance`), and
/// the corpus carries a **trigram inverted index** so a query of 3+ bytes
/// narrows from ~15k docs to a few hundred candidates before scoring. Sub-3-byte
/// tokens fall back to scanning all docs (still cheap on byte arrays). The
/// scoring formulas, field weights, and fuzzy fallback are identical to the
/// previous Character-based implementation — same outputs, ~30-60× faster.
public struct SearchField: Sendable {
    /// Index into `fieldDefinitions` (0..9). A `UInt8` because a Set<String> of
    /// field names was the third-largest allocator in the hot path.
    let nameId: UInt8
    /// Normalized lowercased UTF-8 bytes of the field text.
    let bytes: ContiguousArray<UInt8>
    /// Precomputed ASCII-alnum words for fuzzy fallback. Nil for non-fuzzy
    /// fields; empty array when fuzzy is on but the field has no ASCII words.
    let words: [ContiguousArray<UInt8>]?
    let weight: Double
    let fuzzy: Bool
}

public struct SearchDocument: Sendable {
    public let entry: Entry
    let fields: [SearchField]
}

/// Built corpus + trigram inverted index. Built once at vault load, queried
/// per keystroke. Postings keyed by `(b0<<16)|(b1<<8)|b2` over normalized UTF-8.
public struct SearchIndex: Sendable {
    public let documents: [SearchDocument]
    /// `postings[trigram] -> sorted doc indices that contain the trigram in any field`.
    let postings: [UInt32: ContiguousArray<UInt32>]

    public init(documents: [SearchDocument], postings: [UInt32: ContiguousArray<UInt32>]) {
        self.documents = documents
        self.postings = postings
    }

    public static let empty = SearchIndex(documents: [], postings: [:])
    public var isEmpty: Bool { documents.isEmpty }
}

private struct FieldDefinition {
    let name: String
    let weight: Double
    let fuzzy: Bool
}

private let fieldDefinitions: [FieldDefinition] = [
    FieldDefinition(name: "title",      weight: 120.0, fuzzy: true),
    FieldDefinition(name: "author",     weight:  70.0, fuzzy: true),
    FieldDefinition(name: "book",       weight:  62.0, fuzzy: true),
    FieldDefinition(name: "themes",     weight:  56.0, fuzzy: true),
    FieldDefinition(name: "topics",     weight:  50.0, fuzzy: true),
    FieldDefinition(name: "source",     weight:  44.0, fuzzy: true),
    FieldDefinition(name: "year",       weight:  36.0, fuzzy: false),
    FieldDefinition(name: "path",       weight:  26.0, fuzzy: false),
    FieldDefinition(name: "preview",    weight:  18.0, fuzzy: false),
    FieldDefinition(name: "identifier", weight:  10.0, fuzzy: false),
]
private let identifierFieldId: UInt8 = 9
private let titleFieldId: UInt8 = 0
private let yearFieldId: UInt8 = 6

// MARK: - Public API

public func buildSearchIndex(_ entries: [Entry]) -> SearchIndex {
    let documents = entries.map { SearchDocument(entry: $0, fields: entryFields($0)) }

    // Build trigram postings. Each doc contributes the *unique* set of its
    // 3-byte windows across all fields — duplicates within a field or across
    // fields collapse, so posting lists stay slim.
    var postings: [UInt32: ContiguousArray<UInt32>] = [:]
    postings.reserveCapacity(min(documents.count * 64, 1 << 20))
    var seenInDoc = Set<UInt32>()
    for (i, doc) in documents.enumerated() {
        seenInDoc.removeAll(keepingCapacity: true)
        let docIdx = UInt32(i)
        for field in doc.fields {
            let bs = field.bytes
            if bs.count < 3 { continue }
            bs.withUnsafeBufferPointer { ptr in
                let last = bs.count - 3
                var j = 0
                while j <= last {
                    let tri = (UInt32(ptr[j]) << 16) | (UInt32(ptr[j + 1]) << 8) | UInt32(ptr[j + 2])
                    if seenInDoc.insert(tri).inserted {
                        postings[tri, default: []].append(docIdx)
                    }
                    j += 1
                }
            }
        }
    }
    return SearchIndex(documents: documents, postings: postings)
}

public func searchDocuments(_ index: SearchIndex, _ query: String) -> [(entry: Entry, score: Double)] {
    let prepared = parseSearchQuery(query)
    if prepared.tokens.isEmpty { return [] }

    // Trigram prefilter: per-token rarest posting list, AND-intersected. Yields
    // nil when no token is ≥3 bytes (fall back to a full scan).
    let candidates = candidateDocs(prepared.tokens, postings: index.postings,
                                   totalDocs: index.documents.count)

    let docs = index.documents
    let scoreOne: (Int) -> (Entry, Double)? = { idx in
        let score = rankSearchDocument(docs[idx], prepared)
        return score > 0 ? (docs[idx].entry, score) : nil
    }

    var out: [(entry: Entry, score: Double)] = []
    if let candidates {
        if candidates.isEmpty { return [] }
        out.reserveCapacity(candidates.count)
        for idx in candidates {
            if let row = scoreOne(Int(idx)) { out.append(row) }
        }
    } else {
        out.reserveCapacity(min(docs.count, 1024))
        for idx in docs.indices {
            if let row = scoreOne(idx) { out.append(row) }
        }
    }
    // Stable, deterministic order — tiebreak by path.
    out.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry.path < $1.entry.path }
    return out
}

/// Convenience used by tests; production builds the index once and reuses it.
public func searchEntries(_ entries: [Entry], _ query: String) -> [(entry: Entry, score: Double)] {
    searchDocuments(buildSearchIndex(entries), query)
}

// MARK: - Candidate selection

/// Per-token candidate set = **union of postings for every trigram of the
/// token**, intersected across tokens. Why union and not intersection of the
/// token's own trigrams? A fuzzy-fallback match between query token and a
/// field word can differ by 1-2 edits — that's enough to make 2-3 trigrams
/// disagree, but if the token is long enough, the rest still match. Union
/// catches those fuzzy candidates; intersection across tokens still tightens
/// the multi-token case. False positives get filtered by the real scoring step.
///
/// Returns nil when no token can narrow (fall back to a full scan).
private func candidateDocs(_ tokens: [ContiguousArray<UInt8>],
                           postings: [UInt32: ContiguousArray<UInt32>],
                           totalDocs: Int) -> [UInt32]? {
    var perToken: [Set<UInt32>] = []
    perToken.reserveCapacity(tokens.count)

    for token in tokens {
        if token.count < 3 { continue }   // can't form a trigram → no filter

        // Fuzzy budget can wipe ALL of a token's trigrams when the token is
        // just barely long enough to be fuzzy-eligible: a 5-byte token gets a
        // 1-edit budget against 3 trigrams; an 8-byte token gets a 2-edit
        // budget against 6 trigrams. At those exact lengths the trigram
        // filter could drop a real fuzzy match — fall back to a full scan
        // for that token (and let real scoring handle it). At 6/7 bytes the
        // 1-edit budget still leaves ≥1 shared trigram; at ≥9 bytes the
        // 2-edit budget still leaves ≥1; both are safe to filter.
        if canFuzzyBytes(token) && (token.count == 5 || token.count == 8) { continue }

        var union = Set<UInt32>()
        var sawAny = false
        token.withUnsafeBufferPointer { ptr in
            let last = token.count - 3
            var j = 0
            while j <= last {
                let tri = (UInt32(ptr[j]) << 16) | (UInt32(ptr[j + 1]) << 8) | UInt32(ptr[j + 2])
                if let list = postings[tri] {
                    sawAny = true
                    for d in list { union.insert(d) }
                }
                j += 1
            }
        }
        // Past the fuzzy-safe length check above, "no posting matches" really
        // does mean this token is impossible — neither exact substring nor
        // fuzzy can find it. Bail out fast instead of full-scanning 15k docs.
        if !sawAny { return [] }
        perToken.append(union)
    }

    if perToken.isEmpty { return nil }

    // Intersect smallest-first to keep the working set tiny.
    perToken.sort { $0.count < $1.count }
    var result = perToken[0]
    for next in perToken.dropFirst() {
        result.formIntersection(next)
        if result.isEmpty { return [] }
    }
    return result.sorted()
}

// MARK: - Scoring

struct SearchPrepared {
    let phrase: ContiguousArray<UInt8>
    let tokens: [ContiguousArray<UInt8>]
    /// Mirror copies of the tokens as Strings — only used by the identifier
    /// heuristics, which are easier to reason about on Strings and run once
    /// per token per query (cheap).
    let tokenStrings: [String]
}

func parseSearchQuery(_ query: String) -> SearchPrepared {
    let phrase = normalizeForTokenizing(query.trimmingCharacters(in: .whitespacesAndNewlines))
    let tokenStrings: [String] = splitTokens(normalize(query))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .flatMap { token -> [String] in
            isIdentifierLike(token)
                ? [compactIdentifier(token)]
                : splitTokens(normalizeForTokenizing(token)).filter { !$0.isEmpty }
        }
        .filter { !$0.isEmpty }
    return SearchPrepared(
        phrase: ContiguousArray(phrase.utf8),
        tokens: tokenStrings.map { ContiguousArray($0.utf8) },
        tokenStrings: tokenStrings,
    )
}

func rankSearchDocument(_ doc: SearchDocument, _ query: SearchPrepared) -> Double {
    if query.tokens.isEmpty { return 0 }
    var total = 0.0
    var matchedFieldMask: UInt16 = 0   // bitset over fieldDefinitions indices

    for (i, token) in query.tokens.enumerated() {
        let tokenStr = query.tokenStrings[i]
        let allowIdentifier = shouldSearchIdentifier(tokenStr)
        var best = 0.0
        var bestFieldId: Int = -1
        for field in doc.fields {
            if !shouldSearchField(token, field, allowIdentifier) { continue }
            let score = scoreTokenInField(token, field)
            if score > best { best = score; bestFieldId = Int(field.nameId) }
        }
        if best <= 0 { return 0 }
        total += best
        if bestFieldId >= 0 { matchedFieldMask |= UInt16(1) << bestFieldId }
    }

    total += scorePhrase(query.phrase, doc.fields)
    if matchedFieldMask.nonzeroBitCount == 1 { total += 18 }
    if total > 0 { total += doc.entry.ratingScore * 3 }
    return total
}

private func entryFields(_ entry: Entry) -> [SearchField] {
    let identifierText = (entry.doi ?? "").trimmingCharacters(in: .whitespaces)
    let rawTexts: [String] = [
        entry.title ?? "",
        entry.author.joined(separator: ", "),
        entry.book ?? "",
        entry.themes.joined(separator: " "),
        entry.topics.joined(separator: " "),
        entry.source ?? "",
        entry.year ?? "",
        entry.path,
        entry.preview,
        "\(identifierText) \(compactIdentifier(identifierText))",
    ]
    return rawTexts.enumerated().map { (idx, raw) -> SearchField in
        let def = fieldDefinitions[idx]
        let normalized = normalizeForTokenizing(raw)
        let bytes = ContiguousArray(normalized.utf8)
        let words: [ContiguousArray<UInt8>]?
        if def.fuzzy {
            // Only ASCII-alnum words can match via fuzzy (Levenshtein on bytes
            // requires identical encoding semantics); precompute that subset.
            words = splitWordsString(normalized).compactMap { word in
                isAsciiAlnumString(word) ? ContiguousArray(word.utf8) : nil
            }
        } else {
            words = nil
        }
        return SearchField(nameId: UInt8(idx), bytes: bytes, words: words,
                           weight: def.weight, fuzzy: def.fuzzy)
    }
}

private func scorePhrase(_ phrase: ContiguousArray<UInt8>, _ fields: [SearchField]) -> Double {
    if phrase.count < 3 { return 0 }
    // phrase.contains(" ") — only multi-word phrases get the bonus
    var hasSpace = false
    for b in phrase { if b == 0x20 { hasSpace = true; break } }
    if !hasSpace { return 0 }

    var best = 0.0
    for field in fields {
        if field.nameId == identifierFieldId { continue }
        guard let idx = byteIndexOf(field.bytes, phrase) else { continue }
        best = max(best, field.weight * 2 + positionBoost(field.bytes, byteIdx: idx))
    }
    return best
}

private func scoreTokenInField(_ token: ContiguousArray<UInt8>, _ field: SearchField) -> Double {
    let bytes = field.bytes
    if bytes.isEmpty { return 0 }
    if let idx = byteIndexOf(bytes, token) {
        let boundary = isBoundaryHit(bytes, token, idx)
        let exactWord = boundary && isBoundaryAfter(bytes, idx + token.count)
        let factor = exactWord ? 4.0 : boundary ? 3.0 : 1.7
        return field.weight * factor + positionBoost(bytes, byteIdx: idx)
    }
    if !field.fuzzy || !canFuzzyBytes(token) { return 0 }
    guard let words = field.words, !words.isEmpty else { return 0 }
    var best = 0.0
    let limit = fuzzyLimit(token)
    for word in words {
        if abs(word.count - token.count) > limit { continue }
        guard let distance = levenshteinWithin(token, word, limit) else { continue }
        let factor = distance == 1 ? 1.2 : 0.85
        best = max(best, field.weight * factor)
    }
    return best
}

private func shouldSearchField(_ token: ContiguousArray<UInt8>, _ field: SearchField,
                               _ allowIdentifier: Bool) -> Bool {
    if field.nameId == identifierFieldId { return allowIdentifier }
    if !isShortNumericBytes(token) { return true }
    return field.nameId == titleFieldId || field.nameId == yearFieldId
}

private func shouldSearchIdentifier(_ token: String) -> Bool {
    if token.count >= 8 && token.contains(where: \.isNumber) { return true }
    if isDOIToken(token) { return true }
    if (token.contains("/") || token.contains(".")) && token.count >= 6 { return true }
    if hasIdentifierPrefix(token) { return true }
    return false
}

// MARK: - Token byte helpers

private func isShortNumericBytes(_ bytes: ContiguousArray<UInt8>) -> Bool {
    if bytes.isEmpty || bytes.count >= 5 { return false }
    for b in bytes { if b < 0x30 || b > 0x39 { return false } }
    return true
}

private func canFuzzyBytes(_ bytes: ContiguousArray<UInt8>) -> Bool {
    if bytes.count < 5 { return false }
    var hasLetter = false
    for b in bytes {
        let isDigit = (b >= 0x30 && b <= 0x39)
        let isLower = (b >= 0x61 && b <= 0x7A)
        if !isDigit && !isLower { return false }
        if isLower { hasLetter = true }
    }
    return hasLetter
}

private func fuzzyLimit(_ token: ContiguousArray<UInt8>) -> Int { token.count >= 8 ? 2 : 1 }

// MARK: - Token string helpers (cheap one-per-query path)

private func isIdentifierLike(_ token: String) -> Bool {
    if isDOIToken(token) { return true }
    if hasIdentifierPrefix(token) { return true }
    let hasDigit = token.contains(where: \.isNumber)
    let hasSep = token.contains("-") || token.contains("/") || token.contains(".")
    return hasDigit && hasSep && compactIdentifier(token).count >= 8
}

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
    String(normalize(s).unicodeScalars
        .filter { ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) }
        .map(Character.init))
}

private func isAsciiAlnumString(_ s: String) -> Bool {
    if s.isEmpty { return false }
    for ch in s {
        if !(("a"..."z").contains(ch) || ("0"..."9").contains(ch)) { return false }
    }
    return true
}

// MARK: - Byte-level search & boundary checks

/// SIMD-accelerated substring search via libc `memmem`. Returns the byte
/// offset of the first match, or nil. `memmem` on macOS is implemented in
/// optimized assembly (vectorized scan for the first needle byte, then
/// memcmp on candidates) — far faster than rolling our own loop.
private func byteIndexOf(_ haystack: ContiguousArray<UInt8>, _ needle: ContiguousArray<UInt8>) -> Int? {
    if needle.isEmpty { return 0 }
    if needle.count > haystack.count { return nil }
    var offset: Int = -1
    haystack.withUnsafeBytes { (hb: UnsafeRawBufferPointer) in
        needle.withUnsafeBytes { (nb: UnsafeRawBufferPointer) in
            guard let hbase = hb.baseAddress, let nbase = nb.baseAddress else { return }
            guard let found = memmem(hbase, hb.count, nbase, nb.count) else { return }
            offset = UnsafeRawPointer(found) - hbase
        }
    }
    return offset >= 0 ? offset : nil
}

private func isAsciiAlnumByte(_ b: UInt8) -> Bool {
    (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
}

private func isBoundaryBefore(_ bytes: ContiguousArray<UInt8>, _ byteIdx: Int) -> Bool {
    if byteIdx <= 0 { return true }
    return !isAsciiAlnumByte(bytes[byteIdx - 1])
}

private func isBoundaryAfter(_ bytes: ContiguousArray<UInt8>, _ byteIdx: Int) -> Bool {
    if byteIdx >= bytes.count { return true }
    return !isAsciiAlnumByte(bytes[byteIdx])
}

/// Faithful byte-level port of the JS `isBoundaryHit`: a hit counts as a
/// word boundary if the previous byte is a non-alnum *or* the match is
/// preceded by a literal space (the "` token`" clause in search.ts).
private func isBoundaryHit(_ bytes: ContiguousArray<UInt8>, _ token: ContiguousArray<UInt8>, _ byteIdx: Int) -> Bool {
    if byteIdx == 0 { return true }
    if isBoundaryBefore(bytes, byteIdx) { return true }
    // Mirror search.ts's " " + token check on the slice [idx-1, idx+token.count).
    // In practice this only fires when the preceding byte is literally a space,
    // which is already covered by isBoundaryBefore; keep it for fidelity.
    if byteIdx - 1 < bytes.count && bytes[byteIdx - 1] == 0x20 {
        if byteIdx + token.count <= bytes.count {
            var ok = true
            for k in 0..<token.count {
                if bytes[byteIdx + k] != token[k] { ok = false; break }
            }
            if ok { return true }
        }
    }
    return false
}

/// Position bonus is character-based (mirror search.ts). For ASCII text the
/// byte index equals the char index; for multi-byte CJK we count non-UTF-8
/// continuation bytes up to the match. Saturates at 35 so the scan is bounded.
private func positionBoost(_ bytes: ContiguousArray<UInt8>, byteIdx: Int) -> Double {
    var chars = 0
    let limit = min(byteIdx, bytes.count)
    var i = 0
    while i < limit && chars < 35 {
        if (bytes[i] & 0xC0) != 0x80 { chars += 1 }
        i += 1
    }
    return Double(max(0, 35 - chars))
}

// MARK: - String normalization (one-shot at index time, cheap at query time)

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

private let tokenSeparators = Set<Character>([",", "，", ";", "；"])
private func splitTokens(_ s: String) -> [String] {
    s.split(whereSeparator: { $0.isWhitespace || tokenSeparators.contains($0) }).map(String.init)
}

private let wordSeparators = Set<Character>([
    ",", "，", ";", "；", ":", "：", "/", "\\", "(", ")", "[", "]", "{", "}",
    "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "|", "*",
])
private func splitWordsString(_ s: String) -> [String] {
    s.split(whereSeparator: { $0.isWhitespace || wordSeparators.contains($0) }).map(String.init)
}

// MARK: - Banded Levenshtein on bytes (ASCII only — gated by canFuzzyBytes)

private func levenshteinWithin(_ a: ContiguousArray<UInt8>, _ b: ContiguousArray<UInt8>, _ maxDist: Int) -> Int? {
    if abs(a.count - b.count) > maxDist { return nil }
    if a.isEmpty { return b.count <= maxDist ? b.count : nil }
    if b.isEmpty { return a.count <= maxDist ? a.count : nil }

    var prev = [Int](0...b.count)
    var cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        cur[0] = i
        var rowMin = i
        let ai = a[i - 1]
        for j in 1...b.count {
            let cost = ai == b[j - 1] ? 0 : 1
            let v = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            cur[j] = v
            if v < rowMin { rowMin = v }
        }
        if rowMin > maxDist { return nil }
        swap(&prev, &cur)
    }
    let distance = prev[b.count]
    return distance <= maxDist ? distance : nil
}
