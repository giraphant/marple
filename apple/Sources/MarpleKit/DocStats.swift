import Foundation

public struct DocStats: Equatable, Sendable {
    public let chars: Int
    public let charsNoSpace: Int
    public let words: Int
    public let paragraphs: Int
    public let minutes: Int
}

// CJK ideograph ranges mirrored from src/doc-stats.ts CJK_RE.
private func isCJK(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x3400...0x4DBF,   // CJK Ext A
         0x4E00...0x9FFF,   // CJK Unified
         0xF900...0xFAFF,   // CJK Compatibility
         0x3040...0x30FF:   // Hiragana + Katakana
        return true
    default: return false
    }
}

// Latin/digit run member (mirrors LATIN_RUN_RE [A-Za-z0-9À-ɏ]).
private func isLatinRun(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,  // A-Z a-z 0-9
         0x00C0...0x024F:                         // Latin-1 Sup .. Latin Ext-B (À-ɏ)
        return true
    default: return false
    }
}

/// CJK-aware word count: each CJK ideograph = 1 word, each run of Latin/digits
/// = 1 word. Mirrors src/doc-stats.ts countWords.
public func countWords(_ body: String) -> Int {
    var cjk = 0
    var latinRuns = 0
    var inRun = false
    for ch in body.unicodeScalars {
        if isCJK(ch) { cjk += 1; inRun = false; continue }
        if isLatinRun(ch) {
            if !inRun { latinRuns += 1; inRun = true }
        } else {
            inRun = false
        }
    }
    return cjk + latinRuns
}

public func computeDocStats(_ body: String) -> DocStats {
    let chars = body.unicodeScalars.count
    let charsNoSpace = body.unicodeScalars.filter {
        !CharacterSet.whitespacesAndNewlines.contains($0)
    }.count
    let words = countWords(body)
    let minutes = words > 0 ? max(1, Int((Double(words) / 300.0).rounded())) : 0
    return DocStats(chars: chars, charsNoSpace: charsNoSpace, words: words,
                    paragraphs: countParagraphs(body), minutes: minutes)
}

// Mirror /\n\s*\n/ split: count runs of non-blank lines separated by blank lines.
private func countParagraphs(_ body: String) -> Int {
    var count = 0
    var inPara = false
    for line in body.components(separatedBy: "\n") {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            inPara = false
        } else if !inPara {
            count += 1; inPara = true
        }
    }
    return count
}
