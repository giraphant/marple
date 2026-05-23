import Foundation

public struct WikiRef: Equatable, Sendable {
    public let target: String
    public let label: String
}

public enum InlineToken: Equatable, Sendable {
    case text(String)
    case wikilink(target: String, label: String)
}

public enum Wikilink {
    // Private-use sentinel cmark passes through untouched.
    private static let mark = "\u{F8FF}"
    private static let regex = try! NSRegularExpression(pattern: #"\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]"#)

    public static func protect(_ s: String) -> (protected: String, refs: [String: WikiRef]) {
        var refs: [String: WikiRef] = [:]
        var out = ""
        var last = s.startIndex
        var n = 0
        let ns = s as NSString
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: s) else { continue }
            out += s[last..<r.lowerBound]
            let target = ns.substring(with: m.range(at: 1))
            let labelRange = m.range(at: 2)
            let label = labelRange.location == NSNotFound ? target : ns.substring(with: labelRange)
            let key = "\(mark)\(n)\(mark)"
            refs[key] = WikiRef(target: target.trimmingCharacters(in: .whitespaces),
                                label: label.trimmingCharacters(in: .whitespaces))
            out += key
            n += 1
            last = r.upperBound
        }
        out += s[last...]
        return (out, refs)
    }

    public static func restore(_ s: String, _ refs: [String: WikiRef]) -> [InlineToken] {
        guard !refs.isEmpty else { return s.isEmpty ? [] : [.text(s)] }
        var tokens: [InlineToken] = []
        var buffer = ""
        var i = s.startIndex
        func flush() { if !buffer.isEmpty { tokens.append(.text(buffer)); buffer = "" } }
        while i < s.endIndex {
            if s[i] == Character(mark) {
                if let close = s[s.index(after: i)...].firstIndex(of: Character(mark)) {
                    let key = String(s[i...close])
                    if let ref = refs[key] {
                        flush()
                        tokens.append(.wikilink(target: ref.target, label: ref.label))
                        i = s.index(after: close)
                        continue
                    }
                }
            }
            buffer.append(s[i])
            i = s.index(after: i)
        }
        flush()
        return tokens
    }

    public static func tokenize(_ s: String) -> [InlineToken] {
        let (p, refs) = protect(s)
        return restore(p, refs)
    }
}
