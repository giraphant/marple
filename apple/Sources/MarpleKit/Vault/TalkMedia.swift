import Foundation

/// Resolution of a talk's sidecar media files inside its folder-per-object
/// directory (`vault/talks/<slug>/`). Both `talk.md` and `transcript.md` live
/// beside the recording, so the same resolver serves either entry. The
/// recording itself is gitignored and may be absent on a fresh clone — callers
/// must handle nil.
public enum TalkMedia {
    /// Shared stem for a talk's recording sidecars (`recording.mov`,
    /// `recording.srt`, …), per the Quasi talk file layout.
    public static let recordingStem = "recording"
    public static let subtitlesName = "recording.srt"

    /// Pick the playable recording from a directory listing: a
    /// `recording.<ext>` that is neither the `.srt` subtitle sidecar nor a
    /// markdown file. Sorted so the choice is deterministic. Returns nil when no
    /// media file is present.
    public static func mediaFilename(among names: [String]) -> String? {
        names.sorted().first { name in
            let lower = name.lowercased()
            return lower.hasPrefix(recordingStem + ".")
                && lower != subtitlesName
                && !lower.hasSuffix(".md")
        }
    }

    /// The subtitle sidecar filename if present in the listing.
    public static func subtitlesFilename(among names: [String]) -> String? {
        names.first { $0.lowercased() == subtitlesName }
    }
}

// MARK: - SRT subtitles

/// One subtitle cue: a `[start, end)` window (seconds) and its display text.
public struct SRTCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

/// Minimal SubRip (`.srt`) parser, enough to drive a synced caption overlay
/// from a talk's `recording.srt`. Tolerant of CRLF, BOM, and missing index
/// lines; skips blocks whose timing line doesn't parse.
public enum SRT {
    public static func parse(_ content: String) -> [SRTCue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [SRTCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // Drop a leading numeric index line if present.
            if let first = lines.first, Int(first.trimmingCharacters(in: .whitespaces)) != nil {
                lines.removeFirst()
            }
            guard let timing = lines.first,
                  let (start, end) = parseTiming(timing) else { continue }
            let text = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(SRTCue(start: start, end: end, text: text))
        }
        return cues
    }

    /// The cue active at time `t` (seconds), or nil between cues.
    public static func cue(at t: Double, in cues: [SRTCue]) -> String? {
        cues.first { t >= $0.start && t < $0.end }?.text
    }

    private static func parseTiming(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let a = timestamp(parts[0]), let b = timestamp(parts[1]) else { return nil }
        return (a, b)
    }

    /// `HH:MM:SS,mmm` (or `.mmm`) → seconds.
    private static func timestamp(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let hms = s.split(separator: ":").map(String.init)
        guard hms.count == 3,
              let h = Int(hms[0]), let m = Int(hms[1]), let sec = Double(hms[2]) else { return nil }
        return Double(h) * 3600 + Double(m) * 60 + sec
    }
}
