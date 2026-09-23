import Foundation
import Yams

/// Rewrite path-bearing syntax, not arbitrary prose. Local links are resolved
/// before moving their containing page, then made relative to its new location.
enum ArchiveCollectionReferences {
    static func remap(_ path: String, moves: [ArchiveCollectionChange]) -> String {
        for move in moves { let next = move.remap(path); if next != path { return next } }
        return path
    }

    static func rewrite(_ text: String, at path: String, moves: [ArchiveCollectionChange]) -> String {
        var output = text
        // Parse only known frontmatter path fields; preserve every other field and body.
        if let yaml = Frontmatter.split(text).frontmatter,
           let fields = try? Yams.load(yaml: yaml) as? [String: Any] {
            for key in ["archives", "annotates", "path"] {
                if let values = fields[key] as? [String] {
                    let next = values.map { rewriteTarget($0, page: path, moves: moves, wiki: false, structured: true) }
                    if next != values { output = FrontmatterPatch.setSequence(output, key: key, values: next) }
                } else if let value = fields[key] as? String {
                    let next = rewriteTarget(value, page: path, moves: moves, wiki: false, structured: true)
                    if next != value { output = FrontmatterPatch.setScalar(output, key: key, value: next) }
                }
            }
        }
        let patterns = [#"\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]"#,
                        #"!?\[[^\]\n]*\]\(<?([^\s)>]+)>?(?:\s+\"[^\"]*\")?\)"#,
                        #"(?m)^ {0,3}\[[^\]\n]+\]:\s*<?([^\s>]+)>?"#]
        for (kind, pattern) in patterns.enumerated() {
            let regex = try! NSRegularExpression(pattern: pattern)
            let source = output as NSString
            let protected = protectedRanges(output)
            for match in regex.matches(in: output, range: NSRange(location: 0, length: source.length)).reversed() {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                let range = match.range(at: 1)
                let target = source.substring(with: range)
                let replacement = rewriteTarget(target, page: path, moves: moves, wiki: kind == 0, structured: false)
                if replacement != target, let swiftRange = Range(range, in: output) {
                    output.replaceSubrange(swiftRange, with: replacement)
                }
            }
        }
        return output
    }

    private static func protectedRanges(_ text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var offset = 0, start: Int?, marker: Character?, count = 0
        var frontmatter = text.hasPrefix("---\n") || text.hasPrefix("---\r\n")
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length + 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if frontmatter {
                ranges.append(NSRange(location: offset, length: length))
                if offset > 0 && trimmed == "---" { frontmatter = false }
            } else if let fence = marker {
                if trimmed.prefix(while: { $0 == fence }).count >= count && trimmed.allSatisfy({ $0 == fence }) {
                    ranges.append(NSRange(location: start!, length: offset + length - start!))
                    marker = nil; start = nil
                }
            } else if let first = trimmed.first, first == "`" || first == "~", trimmed.prefix(while: { $0 == first }).count >= 3 {
                marker = first; count = trimmed.prefix(while: { $0 == first }).count; start = offset
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                ranges.append(NSRange(location: offset, length: length))
            }
            offset += length
        }
        if let start { ranges.append(NSRange(location: start, length: offset - start)) }
        let inline = try! NSRegularExpression(pattern: #"(`+)[\s\S]*?\1"#)
        ranges += inline.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        return ranges
    }

    private static func rewriteTarget(_ raw: String, page: String, moves: [ArchiveCollectionChange], wiki: Bool, structured: Bool) -> String {
        guard !raw.isEmpty, !raw.contains("://"), !raw.hasPrefix("#"), !raw.hasPrefix("/") else { return raw }
        let split = raw.firstIndex { $0 == "#" || $0 == "?" }
        let part = split.map { String(raw[..<$0]) } ?? raw
        let suffix = split.map { String(raw[$0...]) } ?? ""
        let decoded = part.removingPercentEncoding ?? part
        let vaultRelative = decoded.hasPrefix("archives/")
        let workspaceRelative = decoded.hasPrefix("vault/")
        if wiki && !workspaceRelative && !vaultRelative { return raw } // slug/title references remain stable
        if structured && !workspaceRelative && !vaultRelative { return raw }
        let absolute: String
        if workspaceRelative { absolute = decoded }
        else if vaultRelative { absolute = "vault/" + decoded }
        else {
            absolute = URL(fileURLWithPath: "/" + page).deletingLastPathComponent()
                .appendingPathComponent(decoded).standardizedFileURL.path.dropFirst().description
        }
        let next = remap(absolute, moves: moves)
        let newPage = remap(page, moves: moves)
        guard next != absolute || (!workspaceRelative && !vaultRelative && newPage != page) else { return raw }
        var target = next
        if vaultRelative { target = String(next.dropFirst("vault/".count)) }
        else if !workspaceRelative {
            let base = (newPage as NSString).deletingLastPathComponent.components(separatedBy: "/")
            let dest = next.components(separatedBy: "/")
            var shared = 0
            while shared < min(base.count, dest.count), base[shared] == dest[shared] { shared += 1 }
            target = (Array(repeating: "..", count: base.count - shared) + Array(dest.dropFirst(shared))).joined(separator: "/")
        }
        if part.contains("%") || (!wiki && !structured) {
            target = target.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "()[]#?"))) ?? target
        }
        return target + suffix
    }
}
