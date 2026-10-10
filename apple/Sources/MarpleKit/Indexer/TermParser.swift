import Foundation
import Markdown

/// A direct correspondence as recorded in a document, before search expansion.
public struct TermRecord: Codable, Equatable, Sendable {
    public let chinese: String
    public let english: String
    public let chineseCell: String
    public let englishCell: String
    public let definition: String?
    public let path: String
    public let line: Int
}

public enum TermParser {
    public static let version = 2

    public static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    public static func parse(_ text: String, path: String) -> [TermRecord] {
        // Skip Markdown parsing when there is no terminology-section marker.
        let lower = text.lowercased()
        guard ["关键概念", "关键术语", "术语表", "key concepts", "key terms", "glossary"]
            .contains(where: lower.contains) else { return [] }
        let document = Document(parsing: Wikilink.preprocessForRendering(text))
        var sectionLevel: Int?
        var records: [TermRecord] = []
        for block in document.children {
            if let heading = block as? Heading {
                let title = key(plainText(heading))
                if ["关键概念", "关键术语", "术语表", "key concepts", "key terms", "glossary"]
                    .contains(where: title.contains) {
                    sectionLevel = heading.level
                } else if let level = sectionLevel, heading.level <= level {
                    sectionLevel = nil
                }
            }
            guard sectionLevel != nil, let table = block as? Table else { continue }
            let headers = Array(table.head.cells.map { key(plainText($0)) })
            guard let cn = headers.firstIndex(where: {
                ["概念", "中文", "术语", "中文术语", "概念名称", "concept", "chinese", "chinese term"].contains($0)
            }), let en = headers.firstIndex(where: {
                ["英文", "英文术语", "原文术语", "english", "english term"].contains($0)
            }) else { continue }
            let definition = headers.firstIndex(where: {
                ["定义", "定義", "含义", "核心含义", "说明", "释义", "本章含义", "本章中的含义",
                 "定义与说明", "definition", "meaning"].contains($0)
            })
            for row in table.body.rows {
                let cells = Array(row.cells.map { plainText($0).trimmingCharacters(in: .whitespacesAndNewlines) })
                guard cells.indices.contains(cn), cells.indices.contains(en) else { continue }
                let chinese = cells[cn], english = cells[en]
                guard isSingleTerm(chinese), isSingleTerm(english), key(chinese) != key(english) else { continue }
                let meaning = definition.flatMap { cells.indices.contains($0) ? cells[$0] : nil }
                records.append(TermRecord(chinese: chinese, english: english,
                    chineseCell: chinese, englishCell: english,
                    definition: meaning?.isEmpty == false ? meaning : nil,
                    path: path, line: row.range?.lowerBound.line ?? 1))
            }
        }
        return records
    }

    private static func isSingleTerm(_ cell: String) -> Bool {
        // Skip the entire row when either cell lists multiple terms. Co-occurrence
        // does not establish which terms translate each other.
        !cell.contains("[[") && !cell.contains("]]")
            && !["", "-", "—", "–", "n/a"].contains(key(cell))
            && cell.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r/／；;、")) == nil
    }

    private static func plainText(_ markup: any Markup) -> String {
        if let text = markup as? Markdown.Text { return text.string }
        if let code = markup as? InlineCode { return code.code }
        if let html = markup as? InlineHTML {
            return html.rawHTML.lowercased().hasPrefix("<br") ? "\n" : ""
        }
        if markup is SoftBreak || markup is LineBreak { return "\n" }
        return markup.children.map { plainText($0) }.joined()
    }
}
