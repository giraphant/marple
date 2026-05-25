import Foundation
import Markdown

public enum RenderBlock: Equatable, Sendable {
    case heading(level: Int, [InlineToken])
    case paragraph([InlineToken])
    case bulletList([[InlineToken]])
    case orderedList([[InlineToken]])
    case quote([InlineToken])
    case codeBlock(language: String?, code: String)
    case thematicBreak
    case table(headers: [[InlineToken]], rows: [[[InlineToken]]])
}

public enum MarkdownModel {
    public static func blocks(from body: String) -> [RenderBlock] {
        let (protected, refs) = Wikilink.protect(stripLeadingKVBlock(body))
        let document = Document(parsing: protected)
        var blocks: [RenderBlock] = []
        for child in document.children {
            appendBlock(child, refs: refs, into: &blocks)
        }
        return blocks
    }

    /// Drop the leading metadata block — the run of `**label**：value` lines that
    /// many vault docs place right under the H1 (原标题 / 作者 / 来源 / DOI). These
    /// belong in the Inspector, not the rendered prose. Only paragraphs *before*
    /// the first real (non-heading) content are eligible, so a stray KV-shaped
    /// line deeper in the body is left untouched. Reuses the indexer's `isKVLabel`.
    private static func stripLeadingKVBlock(_ body: String) -> String {
        let paragraphs = body.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        var kept: [String] = []
        var sawContent = false
        for paragraph in paragraphs {
            let lines = paragraph
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !sawContent, !lines.isEmpty, lines.allSatisfy(isKVLabel) {
                continue
            }
            if !sawContent, let first = lines.first, !first.hasPrefix("#") {
                sawContent = true
            }
            kept.append(paragraph)
        }
        return kept.joined(separator: "\n\n")
    }

    private static func inline(_ markup: Markup, _ refs: [String: WikiRef]) -> [InlineToken] {
        Wikilink.restore(plainText(of: markup), refs)
    }

    private static func appendBlock(_ markup: Markup, refs: [String: WikiRef],
                                    into blocks: inout [RenderBlock]) {
        switch markup {
        case let h as Heading:
            blocks.append(.heading(level: h.level, inline(h, refs)))
        case let p as Paragraph:
            blocks.append(.paragraph(inline(p, refs)))
        case let list as UnorderedList:
            blocks.append(.bulletList(list.listItems.map { inline($0, refs) }))
        case let list as OrderedList:
            blocks.append(.orderedList(list.listItems.map { inline($0, refs) }))
        case let q as BlockQuote:
            blocks.append(.quote(inline(q, refs)))
        case let code as CodeBlock:
            let lang = (code.language?.isEmpty == false) ? code.language : nil
            blocks.append(.codeBlock(language: lang, code: code.code))
        case is ThematicBreak:
            blocks.append(.thematicBreak)
        case let table as Table:
            let headers: [[InlineToken]] = table.head.cells.map { inline($0, refs) }
            let rows: [[[InlineToken]]] = table.body.rows.map { row in
                row.cells.map { inline($0, refs) }
            }
            blocks.append(.table(headers: headers, rows: rows))
        default:
            let text = plainText(of: markup)
            if !text.isEmpty { blocks.append(.paragraph(Wikilink.restore(text, refs))) }
        }
    }

    /// Visible inline text only (drops emphasis markers) while preserving the
    /// F8FF wikilink sentinels so restore() can recover links.
    private static func plainText(of markup: Markup) -> String {
        var s = ""
        collect(markup, into: &s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collect(_ markup: Markup, into s: inout String) {
        if let t = markup as? Text { s += t.string; return }
        if let c = markup as? InlineCode { s += c.code; return }
        if markup is SoftBreak || markup is LineBreak { s += " "; return }
        for child in markup.children { collect(child, into: &s) }
    }
}
