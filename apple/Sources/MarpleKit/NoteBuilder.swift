import Foundation

/// A new note's destination path, full file text, and human title.
public struct NoteDraft: Equatable, Sendable {
    public let path: String
    public let text: String
    public let title: String
    public init(path: String, text: String, title: String) {
        self.path = path; self.text = text; self.title = title
    }
}

/// Builds new-note drafts. Pure; `today`/`stamp` injectable for deterministic tests.
/// Mirrors src/api.ts newIdeaDraft / newAnnotationDraft / slugify.
public enum NoteBuilder {
    static let notesDir = "vault/notes/"

    /// Standalone idea note: vault/notes/<date>-idea-<stamp>.md
    public static func ideaNote(today: Date = Date(),
                                stamp: String = NoteBuilder.stamp()) -> NoteDraft {
        let date = isoDate(today)
        let path = "\(notesDir)\(date)-idea-\(stamp).md"
        let title = "\(date) — 新笔记"
        let text = """
        ---
        type: note
        title: \(FrontmatterPatch.yamlScalar(title))
        created: \(date)
        themes: []
        ---

        # \(title)


        """
        return NoteDraft(path: path, text: text, title: title)
    }

    /// Annotation note targeting `target`: vault/notes/<slug>-note-<stamp>.md
    public static func annotation(target: Entry, today: Date = Date(),
                                  stamp: String = NoteBuilder.stamp()) -> NoteDraft {
        let date = isoDate(today)
        let stem = (target.path as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
        let slug = slugify(stem)
        let path = "\(notesDir)\(slug)-note-\(stamp).md"
        let title = "对《\(target.title ?? stem)》的批注"
        let text = """
        ---
        type: note
        title: \(FrontmatterPatch.yamlScalar(title))
        annotates: \(target.path)
        created: \(date)
        themes: []
        ---

        # \(title)


        """
        return NoteDraft(path: path, text: text, title: title)
    }

    /// Last 4 base-36 chars of the current epoch-ms (matches the web stamp).
    public static func stamp() -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        return String(String(ms, radix: 36).suffix(4))
    }

    /// UTC yyyy-MM-dd (matches `new Date().toISOString().slice(0,10)`).
    static func isoDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Port of src/api.ts slugify: lowercase, non-[a-z0-9_] runs → "-",
    /// trim "-", cap 60, fallback "note".
    static func slugify(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        var out = ""
        var prevDash = false
        for ch in s.lowercased() {
            if allowed.contains(ch) {
                out.append(ch); prevDash = false
            } else if !prevDash {
                out.append("-"); prevDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        out = String(out.prefix(60))
        return out.isEmpty ? "note" : out
    }
}
