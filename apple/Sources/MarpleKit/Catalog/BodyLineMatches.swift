import Foundation

/// A highlight span within a displayed excerpt (UTF-16 offsets into `excerpt`).
public struct BodyMatchSpan: Sendable, Equatable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// One body line that contains ≥1 query match, prepared for display + jump.
public struct BodyMatchLine: Sendable, Equatable, Identifiable {
    /// 0-based physical line index in the body (stable list identity).
    public let lineIndex: Int
    /// Cleaned, windowed text actually shown in the row.
    public let excerpt: String
    /// Highlight ranges within `excerpt`.
    public let spans: [BodyMatchSpan]
    /// Index of this line's FIRST match within the document's ordered match list —
    /// the reader's ordinal fallback when the anchor can't be located.
    public let matchOrdinal: Int
    /// Full plain-text projection of the line. The reader locates the jump by
    /// finding this in the rendered text (precise, drift-proof), then highlights
    /// the term inside it.
    public let anchor: String
    public var id: Int { lineIndex }
    public init(lineIndex: Int, excerpt: String, spans: [BodyMatchSpan],
                matchOrdinal: Int, anchor: String) {
        self.lineIndex = lineIndex
        self.excerpt = excerpt
        self.spans = spans
        self.matchOrdinal = matchOrdinal
        self.anchor = anchor
    }
}

/// All matched lines of a single document plus the total match count (for the
/// "再显示 N 个匹配项" affordance).
public struct BodyMatches: Sendable, Equatable {
    public let lines: [BodyMatchLine]
    public let totalMatches: Int
    public init(lines: [BodyMatchLine], totalMatches: Int) {
        self.lines = lines
        self.totalMatches = totalMatches
    }
    public static let empty = BodyMatches(lines: [], totalMatches: 0)
}

/// Group every literal match in `body` into per-line display excerpts. Pure +
/// deterministic; the heavy lifting (whole-body match offsets) is shared with the
/// reader via `BodyMatching.ranges`.
///
/// - leadContext: characters of context kept before the first match before a
///   leading "…" is added.
/// - maxExcerpt: max characters of the windowed core (a trailing "…" marks a cut).
public func bodyLineMatches(body: String, query: String,
                            leadContext: Int = 8, maxExcerpt: Int = 90) -> BodyMatches {
    let terms = BodyMatching.terms(from: query)
    guard !terms.isEmpty else { return .empty }

    // Physical lines (no terminators). enumerateSubstrings(.byLines) drops a final
    // empty line, which never carries a match anyway.
    var lines: [String] = []
    body.enumerateSubstrings(in: body.startIndex..., options: [.byLines]) { sub, _, _, _ in
        lines.append(sub ?? "")
    }

    var out: [BodyMatchLine] = []
    var ordinal = 0
    for (lineIndex, rawLine) in lines.enumerated() {
        // Match over the plain-text projection so excerpts read cleanly and the
        // ordinal aligns with the reader's rendered text.
        let plain = MarkdownLine.plainText(rawLine)
        if plain.isEmpty { continue }
        let lineMatches = BodyMatching.ranges(in: plain, terms: terms)
        guard !lineMatches.isEmpty else { continue }

        let firstOrdinal = ordinal
        ordinal += lineMatches.count
        let rel = lineMatches.map { (loc: $0.location, len: $0.length) }
        let (excerpt, spans) = windowExcerpt(plain, matches: rel,
                                             leadContext: leadContext, maxExcerpt: maxExcerpt)
        out.append(BodyMatchLine(lineIndex: lineIndex, excerpt: excerpt, spans: spans,
                                 matchOrdinal: firstOrdinal, anchor: plain))
    }
    return BodyMatches(lines: out, totalMatches: ordinal)
}

/// Remove a leading block marker (heading `#`, blockquote `>`, list `-`/`*`/`+`,
/// ordered `1.`) plus surrounding whitespace from a line for display. Returns the
/// cleaned text and how many UTF-16 units were removed from the front.
func stripLeadingMarker(_ line: String) -> (cleaned: String, removedPrefix: Int) {
    let ns = line as NSString
    var i = 0
    func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    // leading whitespace
    while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
    let markerStart = i
    let c = i < ns.length ? ns.character(at: i) : 0
    switch c {
    case 0x23: // '#'
        var h = 0
        while i < ns.length, ns.character(at: i) == 0x23, h < 6 { i += 1; h += 1 }
        if i < ns.length, isSpace(ns.character(at: i)) {
            while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
        } else { i = markerStart }   // "#tag" isn't a heading marker
    case 0x3E: // '>'
        i += 1
        while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
    case 0x2D, 0x2A, 0x2B: // '-', '*', '+'
        if i + 1 < ns.length, isSpace(ns.character(at: i + 1)) {
            i += 1
            while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
        } else { i = markerStart }
    case 0x30...0x39: // digit → ordered list "12. "
        var j = i
        while j < ns.length, (0x30...0x39).contains(ns.character(at: j)) { j += 1 }
        if j < ns.length, ns.character(at: j) == 0x2E,
           j + 1 < ns.length, isSpace(ns.character(at: j + 1)) {
            i = j + 1
            while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
        } else { i = markerStart }
    default:
        break
    }
    // Also trim trailing whitespace.
    var end = ns.length
    while end > i, isSpace(ns.character(at: end - 1)) { end -= 1 }
    let cleaned = ns.substring(with: NSRange(location: i, length: max(0, end - i)))
    return (cleaned, i)
}

/// Window `text` around its first match (≤ maxExcerpt chars of core), adding "…"
/// markers where it was cut, and remap/clamp spans into the windowed excerpt.
func windowExcerpt(_ text: String, matches: [(loc: Int, len: Int)],
                   leadContext: Int, maxExcerpt: Int) -> (excerpt: String, spans: [BodyMatchSpan]) {
    let ns = text as NSString
    guard let first = matches.first else {
        let core = ns.length > maxExcerpt
            ? ns.substring(with: NSRange(location: 0, length: maxExcerpt)) + "…"
            : text
        return (core, [])
    }
    let cut = first.loc > leadContext ? first.loc - leadContext : 0
    let end = min(ns.length, cut + maxExcerpt)
    let core = ns.substring(with: NSRange(location: cut, length: end - cut))
    let prefix = cut > 0 ? "…" : ""
    let suffix = end < ns.length ? "…" : ""
    let excerpt = prefix + core + suffix
    let shift = (cut > 0 ? 1 : 0) - cut   // text-offset → excerpt-offset
    var spans: [BodyMatchSpan] = []
    for m in matches {
        guard m.loc >= cut, m.loc < end else { continue }   // outside the window
        let newLoc = m.loc + shift
        let clampedLen = min(m.len, end - m.loc)             // clamp a trailing-cut match
        if clampedLen > 0 { spans.append(BodyMatchSpan(location: newLoc, length: clampedLen)) }
    }
    return (excerpt, spans)
}
