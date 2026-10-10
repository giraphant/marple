import Foundation
import MarpleKit

enum ReaderLink: Equatable {
    case document(path: String, fragment: String?)
    case external(URL)

    static func url(from destination: String) -> URL? {
        // Foundation otherwise double-encodes existing escapes when a link also
        // contains unescaped Unicode (e.g. 中文%20材料.md).
        let allowed = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "#%[]"))
        return destination.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }

    /// Resolve Markdown paths against the current document, before AppKit can
    /// hand an unresolved relative URL to Launch Services (which fails with -50).
    static func resolve(_ url: URL, from documentPath: String, workspaceRoot: String) -> ReaderLink {
        if url.scheme == nil, url.host != nil {
            return .external(URL(string: "https:" + url.absoluteString)!)
        }
        guard url.scheme == nil || url.isFileURL else { return .external(url) }
        let fragment = url.fragment?.removingPercentEncoding
        if url.scheme == nil, url.path.isEmpty {
            return .document(path: documentPath, fragment: fragment)
        }
        let root = URL(fileURLWithPath: workspaceRoot.isEmpty ? "/" : workspaceRoot,
                       isDirectory: true).standardizedFileURL
        let base = root.appendingPathComponent(documentPath)
        let resolved = URL(string: url.relativeString, relativeTo: base)!.absoluteURL.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if resolved.path.hasPrefix(prefix), ["md", "markdown"].contains(resolved.pathExtension.lowercased()) {
            return .document(path: String(resolved.path.dropFirst(prefix.count)), fragment: fragment)
        }
        return .external(resolved)
    }

    /// Markdown heading IDs keep letters (including Chinese), numbers, hyphens
    /// and underscores; spaces become hyphens, and repeated IDs get -1, -2, ….
    static func headingRange(for fragment: String, in headings: [HeadingAnchor]) -> NSRange? {
        if fragment.isEmpty { return NSRange(location: 0, length: 0) }
        var used: Set<String> = []
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: "-_"))
        for heading in headings {
            let text = heading.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = text.lowercased().unicodeScalars.reduce(into: "") { slug, scalar in
                if CharacterSet.whitespaces.contains(scalar) { slug += "-" }
                else if allowed.contains(scalar) { slug.unicodeScalars.append(scalar) }
            }
            var slug = base
            var suffix = 0
            while used.contains(slug) { suffix += 1; slug = "\(base)-\(suffix)" }
            used.insert(slug)
            if fragment == slug || fragment == text { return heading.range }
        }
        return nil
    }
}
