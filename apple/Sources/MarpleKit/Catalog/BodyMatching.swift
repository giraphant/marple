import Foundation

/// Literal query matching shared by BOTH the list (matched-line excerpts) and the
/// reader (in-document highlight + jump). Both call `ranges(in:terms:)`, so the
/// Nth occurrence counted over the body equals the Nth occurrence counted over the
/// rendered text for the vault's CJK prose (markdown syntax is ASCII; query terms
/// are words) — that consistency is what lets a clicked list line scroll the reader
/// to the right match by ordinal.
public enum BodyMatching {
    /// Split a query into literal terms (whitespace-separated). A line is a match if
    /// it contains ANY term; each term's occurrences are highlighted independently.
    public static func terms(from query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Every occurrence of any term in `text`, as ordered, overlap-merged `NSRange`s
    /// (UTF-16 offsets, matching NSString / NSAttributedString / NSTextView indexing).
    /// Case- and diacritic-insensitive so "cafe" hits "Café" and case folds for Latin;
    /// CJK has neither, so it is exact-substring there.
    public static func ranges(in text: String, terms: [String]) -> [NSRange] {
        guard !text.isEmpty, !terms.isEmpty else { return [] }
        let ns = text as NSString
        var found: [NSRange] = []
        for term in terms where !term.isEmpty {
            var start = 0
            while start < ns.length {
                let scope = NSRange(location: start, length: ns.length - start)
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: scope)
                if r.location == NSNotFound { break }
                found.append(r)
                start = r.location + max(r.length, 1)   // +1 guard against zero-width loops
            }
        }
        return mergeSorted(found)
    }

    /// Convenience over a raw query string.
    public static func ranges(in text: String, query: String) -> [NSRange] {
        ranges(in: text, terms: terms(from: query))
    }

    /// Resolve which match range a clicked search line should scroll to, given the
    /// rendered text, its match ranges (from `ranges(in:terms:)`), the clicked line's
    /// plain-text `anchor`, and the line's `ordinal`.
    ///
    /// The `ordinal` (counted over the plain-text projection) is aligned with the
    /// rendered matches, so it disambiguates two identical lines. The `anchor`
    /// corrects the rare case where the projection diverges from the renderer and the
    /// ordinal drifts. Precedence: the anchor occurrence that *contains* the ordinal
    /// match (exact) → the first anchor occurrence's first inner match (anchor wins) →
    /// the ordinal match (no anchor located).
    public static func resolveJumpTarget(in text: String, matchRanges: [NSRange],
                                         anchor: String, ordinal: Int) -> NSRange? {
        guard !matchRanges.isEmpty else { return nil }
        let ordinalRange = matchRanges[min(max(0, ordinal), matchRanges.count - 1)]
        guard !anchor.isEmpty else { return ordinalRange }

        let ns = text as NSString
        var occurrences: [NSRange] = []
        var from = 0
        while from < ns.length {
            let a = ns.range(of: anchor, range: NSRange(location: from, length: ns.length - from))
            if a.location == NSNotFound { break }
            occurrences.append(a)
            from = a.location + max(a.length, 1)
        }
        func contains(_ outer: NSRange, _ loc: Int) -> Bool {
            loc >= outer.location && loc < outer.location + outer.length
        }
        if occurrences.contains(where: { contains($0, ordinalRange.location) }) {
            return ordinalRange
        }
        if let first = occurrences.first {
            return matchRanges.first { contains(first, $0.location) } ?? first
        }
        return ordinalRange
    }

    /// Sort by location (longer first on ties) then merge strictly-overlapping ranges,
    /// so the same span found by two terms collapses to one. Touching-but-not-overlapping
    /// ranges stay separate (adjacent distinct terms remain distinct counts).
    static func mergeSorted(_ ranges: [NSRange]) -> [NSRange] {
        guard ranges.count > 1 else { return ranges }
        let sorted = ranges.sorted {
            $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length
        }
        var out: [NSRange] = []
        for r in sorted {
            if var last = out.last, r.location < last.location + last.length {
                let end = max(last.location + last.length, r.location + r.length)
                last.length = end - last.location
                out[out.count - 1] = last
            } else {
                out.append(r)
            }
        }
        return out
    }
}
