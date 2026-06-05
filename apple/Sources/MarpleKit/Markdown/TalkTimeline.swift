import Foundation

/// Talk / transcript timeline helpers: parsing `[mm:ss]` / `[hh:mm:ss]` markers
/// and turning the backtick-wrapped timestamps that pepper a talk's 时间脉络
/// section (and a transcript's body) into clickable `marple://seek/<seconds>`
/// links the reader intercepts to drive the media player.
///
/// Keying is by the timestamp *token*, never by section position: the 时间脉络
/// H2 sits second in older talks and last in newer ones, and inline `[mm:ss]`
/// also appear in 分节摘要, so every backtick timestamp in the body is made
/// seekable regardless of where it lives.
public enum TalkTimeline {
    /// Scheme + host for seek links (the scheme is shared with `WikiURL`).
    public static let scheme = "marple"
    public static let host = "seek"

    /// Parse a `[mm:ss]` or `[hh:mm:ss]` timestamp (surrounding brackets
    /// optional) into a count of seconds. Returns nil when the shape doesn't
    /// match (wrong field count, non-numeric, or a 60+ minutes/seconds field).
    public static func seconds(fromTimestamp raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Int(p), v >= 0 else { return nil }
            // Every field except the leading one is a 0–59 sexagesimal digit.
            if i > 0 && v >= 60 { return nil }
            total = total * 60 + Double(v)
        }
        return total
    }

    // Backtick-wrapped `[h:mm:ss]` / `[mm:ss]` token. Capture group 1 is the
    // bracketed timestamp without the backticks.
    private static let regex = try! NSRegularExpression(
        pattern: "`(\\[\\d{1,2}(?::\\d{2}){1,2}\\])`")

    /// Replace backtick-wrapped timestamps with markdown links to
    /// `marple://seek/<seconds>`. Callers apply this only to talk / transcript
    /// bodies *and* only when a media file exists, so other documents and
    /// media-less clones keep the timestamps as plain inline code.
    public static func linkifyTimestamps(_ markdown: String) -> String {
        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return markdown }
        // Single forward pass: copy the gaps between matches and swap each token
        // for its link, so a long transcript (~hundreds of timestamps) costs one
        // string build rather than one full-string copy per match.
        var out = ""
        out.reserveCapacity(ns.length + matches.count * 24)
        var cursor = 0
        for m in matches {
            let token = ns.substring(with: m.range(at: 1))   // e.g. "[01:03:20]"
            guard let secs = seconds(fromTimestamp: token) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let label = token.replacingOccurrences(of: "[", with: "\\[")
                             .replacingOccurrences(of: "]", with: "\\]")
            out += "[\(label)](\(scheme)://\(host)/\(Int(secs)))"
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
