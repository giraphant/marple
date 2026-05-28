import Foundation
import MarpleKit

enum MetadataAction: Equatable {
    case title
    case year
    case imageAuthor
    case source
    case doi
    case topic
}

enum InspectorInfoRow: Equatable {
    case rating
    case authors
    case editableScalar(label: String, value: String?, action: MetadataAction)
    case readOnlyScalar(label: String, value: String, copyValue: String?)
    case identifier(label: String, displayValue: String, fullValue: String)
}

// Keep this presentation policy in sync with the Quasi plugin schemas at ~/.agents/plugins/quasi/scripts/schemas.
func inspectorInfoRows(for entry: Entry, in entries: [Entry] = []) -> [InspectorInfoRow] {
    switch entry.type {
    case .paper:   return paperRows(for: entry)
    case .book:    return bookRows(for: entry)
    case .chapter: return chapterRows(for: entry, in: entries)
    case .author:  return [.rating]
    case .topic:   return topicRows(for: entry)
    case .journal: return journalRows(for: entry)
    case .note:    return noteRows(for: entry, in: entries)
    case .image:   return imageRows(for: entry)
    case .other:   return []
    }
}

private func paperRows(for entry: Entry) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = [.authors]
    if let year = nonEmpty(entry.year) {
        rows.append(.readOnlyScalar(label: "年份", value: year, copyValue: nil))
    }
    if let journal = nonEmpty(entry.journal) ?? nonEmpty(entry.source) {
        rows.append(.readOnlyScalar(label: "期刊", value: journal, copyValue: nil))
    }
    if let doi = nonEmpty(entry.doi) {
        rows.append(.identifier(label: "DOI", displayValue: doiDisplayValue(doi), fullValue: doi))
    }
    rows.append(.rating)
    return rows
}

private func bookRows(for entry: Entry) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = [.authors]
    if let year = nonEmpty(entry.year) {
        rows.append(.readOnlyScalar(label: "年份", value: year, copyValue: nil))
    }
    if let publisher = nonEmpty(entry.publisher) {
        rows.append(.readOnlyScalar(label: "出版", value: publisher, copyValue: nil))
    }
    if let category = nonEmpty(entry.category) {
        rows.append(.readOnlyScalar(label: "类型", value: categoryDisplayValue(category), copyValue: category))
    }
    if let isbn = nonEmpty(entry.isbn) {
        rows.append(.identifier(label: "ISBN", displayValue: isbnDisplayValue(isbn), fullValue: isbn))
    } else if let doi = nonEmpty(entry.doi) {
        rows.append(.identifier(label: "DOI", displayValue: doiDisplayValue(doi), fullValue: doi))
    }
    rows.append(.rating)
    return rows
}

private func chapterRows(for entry: Entry, in entries: [Entry]) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = [.authors]
    if let year = nonEmpty(entry.year) {
        rows.append(.readOnlyScalar(label: "年份", value: year, copyValue: nil))
    }
    if let book = nonEmpty(entry.book) {
        let overview = bookContext(for: entry, in: entries)?.overview
        rows.append(.readOnlyScalar(label: "书籍", value: displayTitle(for: overview) ?? book, copyValue: book))
    }
    rows.append(.rating)
    return rows
}

private func topicRows(for entry: Entry) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = []
    if let kind = nonEmpty(entry.kind) {
        rows.append(.readOnlyScalar(label: "类型", value: kindDisplayValue(kind), copyValue: kind))
    }
    if let topic = nonEmpty(entry.topic) {
        rows.append(.readOnlyScalar(label: "专题", value: topic, copyValue: nil))
    }
    return rows
}

private func journalRows(for entry: Entry) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = []
    if let kind = nonEmpty(entry.kind) {
        rows.append(.readOnlyScalar(label: "类型", value: kindDisplayValue(kind), copyValue: kind))
    }
    if let journal = nonEmpty(entry.journal) ?? nonEmpty(entry.title) {
        rows.append(.readOnlyScalar(label: "期刊", value: journal, copyValue: nil))
    }
    return rows
}

private func noteRows(for entry: Entry, in entries: [Entry]) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = []
    if let created = nonEmpty(entry.created) {
        rows.append(.readOnlyScalar(label: "创建", value: created, copyValue: nil))
    }
    if let annotates = nonEmpty(entry.annotates) {
        let target = entries.first { $0.path == annotates }
        rows.append(.readOnlyScalar(label: "标注", value: displayTitle(for: target) ?? annotates, copyValue: annotates))
    }
    return rows
}

private func imageRows(for entry: Entry) -> [InspectorInfoRow] {
    [.editableScalar(label: "名称", value: entry.title, action: .title)]
}

private func displayTitle(for entry: Entry?) -> String? {
    if let title = nonEmpty(entry?.title) {
        return title
    }
    guard let path = entry?.path else { return nil }
    return (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func categoryDisplayValue(_ category: String) -> String {
    switch category.lowercased() {
    case "monograph": return "专著"
    case "edited volume", "edited-volume": return "编著"
    default: return category
    }
}

private func kindDisplayValue(_ kind: String) -> String {
    switch kind.lowercased() {
    case "overview": return "概览"
    case "resources": return "资源"
    default: return kind
    }
}

private func isbnDisplayValue(_ isbn: String) -> String {
    let compact = isbn.filter { $0.isNumber || $0.isLetter }
    guard compact.count > 10 else { return compact.isEmpty ? isbn : compact }
    return String(compact.prefix(3)) + "…" + String(compact.suffix(4))
}

private func doiDisplayValue(_ doi: String) -> String {
    guard doi.count > 12 else { return doi }
    return String(doi.prefix(11)) + "…"
}

/// Human-readable label for a schema field name surfaced by the conformance
/// checker. Falls back to the raw name for fields this build doesn't translate
/// (a newer Quasi schema could add one) so the banner degrades gracefully.
func conformanceFieldLabel(_ field: String) -> String {
    switch field {
    case "title":     return "标题"
    case "name":      return "名称"
    case "authors", "author": return "作者"
    case "year":      return "年份"
    case "journal":   return "期刊"
    case "themes":    return "主题"
    case "publisher": return "出版"
    case "book":      return "书籍"
    case "kind":      return "类型"
    case "topic":     return "专题"
    case "created":   return "创建"
    default:          return field
    }
}
