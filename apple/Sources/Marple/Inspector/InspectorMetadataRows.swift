import Foundation
import MarpleKit

enum MetadataAction: Equatable {
    case title
    case year
    case imageAuthor
    /// Image creation/capture date — writes the `date:` frontmatter key
    /// (indexed into `created`, QUA-175).
    case imageDate
    case source
    case doi
}

struct InspectorInfoChip: Equatable {
    let title: String
    let path: String?
    let copyValue: String?
}

enum InspectorInfoRow: Equatable {
    case rating
    case authors
    case editableScalar(label: String, value: String?, action: MetadataAction)
    case readOnlyScalar(label: String, value: String, copyValue: String?)
    case linkedScalar(label: String, value: String, path: String, copyValue: String?)
    case chips(label: String, values: [InspectorInfoChip])
    case identifier(label: String, displayValue: String, fullValue: String)
}

// Keep this presentation policy in sync with the Quasi plugin schemas at ~/.agents/plugins/quasi/scripts/schemas.
func inspectorInfoRows(for entry: Entry, in entries: [Entry] = [],
                       localise: CnDoubanIndex? = nil) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow]
    switch entry.type {
    case .paper:   rows = paperRows(for: entry, in: entries)
    case .book:    rows = bookRows(for: entry)
    case .chapter: rows = chapterRows(for: entry, in: entries)
    case .author:  rows = [.rating]
    case .topic:   rows = topicRows(for: entry)
    case .journal: rows = journalRows(for: entry)
    case .note:    rows = noteRows(for: entry, in: entries)
    case .image:   rows = imageRows(for: entry)
    case .talk:    rows = talkRows(for: entry, in: entries)
    case .transcript: rows = transcriptRows(for: entry, in: entries)
    case .other:   rows = []
    }
    // "专题": topic-corpus membership (QUA-137). Read-only chips inserted before
    // the trailing rating row so identity/attribution metadata stays grouped above
    // the rating.
    if let membership = topicsMembershipRow(for: entry, in: entries) {
        if let last = rows.last, last == .rating {
            rows.insert(membership, at: rows.count - 1)
        } else {
            rows.append(membership)
        }
    }
    // "译本": Chinese translation edition, slotted directly above the rating
    // (and below 专题, which inserted just before rating above).
    if let translation = translationRow(for: entry, in: entries, localise: localise) {
        if let last = rows.last, last == .rating {
            rows.insert(translation, at: rows.count - 1)
        } else {
            rows.append(translation)
        }
    }
    return rows
}

/// Row for a book's Chinese translation, resolved from the `cndouban.json`
/// sidecar by ISBN, linking to its Douban page when a URL is available. The
/// translation is keyed off the book, so for a chapter we resolve it from the
/// parent book overview (mirrors how `bookDetailRows` sources the overview).
/// Returns nil when the book has no indexed Chinese edition.
private func translationRow(for entry: Entry, in entries: [Entry], localise: CnDoubanIndex?) -> InspectorInfoRow? {
    guard let localise else { return nil }
    let source = bookContext(for: entry, in: entries)?.overview ?? entry
    guard let translation = localise.translation(forISBN: source.isbn) else { return nil }
    if let url = nonEmpty(translation.doubanURL) {
        return .linkedScalar(label: "译本", value: translation.titleCn, path: url, copyValue: url)
    }
    return .readOnlyScalar(label: "译本", value: translation.titleCn, copyValue: nil)
}

/// Read-only row listing the topic corpora this entry declares membership in
/// (`topics:` frontmatter). Each slug is resolved to its topic page's display
/// title when that page is loaded, falling back to the raw slug. Returns nil
/// when the entry declares no topics.
private func topicsMembershipRow(for entry: Entry, in entries: [Entry]) -> InspectorInfoRow? {
    guard !entry.topics.isEmpty else { return nil }
    let membership = buildTopicMembership(entries)
    let chips = entry.topics.map { slug in
        InspectorInfoChip(
            title: topicDisplayTitle(forSlug: slug, in: entries) ?? slug,
            path: membership.topicEntryBySlug[slug]?.path,
            copyValue: slug
        )
    }
    return .chips(label: "专题", values: chips)
}

private func paperRows(for entry: Entry, in entries: [Entry]) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = [.authors]
    if let year = nonEmpty(entry.year) {
        rows.append(.readOnlyScalar(label: "年份", value: year, copyValue: nil))
    }
    if let journal = nonEmpty(entry.journal) ?? nonEmpty(entry.source) {
        if let target = NameResolver.journalEntry(matching: journal, in: entries) {
            rows.append(.linkedScalar(
                label: "期刊",
                value: journalDisplayTitle(for: target) ?? journal,
                path: target.path,
                copyValue: journal
            ))
        } else {
            rows.append(.readOnlyScalar(label: "期刊", value: journal, copyValue: nil))
        }
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
    rows.append(contentsOf: bookDetailRows(for: entry))
    rows.append(.rating)
    return rows
}

private func chapterRows(for entry: Entry, in entries: [Entry]) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = [.authors]
    if let year = nonEmpty(entry.year) {
        rows.append(.readOnlyScalar(label: "年份", value: year, copyValue: nil))
    }
    let context = bookContext(for: entry, in: entries)
    if let book = nonEmpty(entry.book) ?? context?.slug {
        if let overview = context?.overview {
            rows.append(.linkedScalar(label: "书籍", value: displayTitle(for: overview) ?? book,
                                      path: overview.path, copyValue: book))
            rows.append(contentsOf: bookDetailRows(for: overview))
        } else {
            rows.append(.readOnlyScalar(label: "书籍", value: book, copyValue: book))
        }
    }
    rows.append(.rating)
    return rows
}

private func bookDetailRows(for entry: Entry) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = []
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
    return rows
}

private func topicRows(for entry: Entry) -> [InspectorInfoRow] {
    var rows: [InspectorInfoRow] = []
    if let kind = nonEmpty(entry.kind) {
        rows.append(.readOnlyScalar(label: "类型", value: kindDisplayValue(kind), copyValue: kind))
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
    // `creator` is indexed into `author` (same parse as `authors`, QUA-175), so
    // reuse the standard authors row — it renders 创作者 for images and writes
    // edits back to the `creator:` key (see AppModel.setAuthor).
    var rows: [InspectorInfoRow] = [
        .editableScalar(label: "名称", value: entry.title, action: .title),
        .authors,
        // `date` is indexed into `created` (same fold as talk).
        .editableScalar(label: "日期", value: entry.created, action: .imageDate),
        .editableScalar(label: "来源", value: entry.source, action: .source),
    ]
    // Technical fields, derived from original.<ext> at index time — read-only.
    if let w = entry.width, let h = entry.height {
        rows.append(.readOnlyScalar(label: "尺寸", value: "\(w) × \(h)", copyValue: "\(w)×\(h)"))
    }
    if let bytes = entry.fileSize, bytes > 0 {
        let display = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        rows.append(.readOnlyScalar(label: "大小", value: display, copyValue: nil))
    }
    rows.append(.rating)
    return rows
}

private func talkRows(for entry: Entry, in entries: [Entry]) -> [InspectorInfoRow] {
    // `speaker` is indexed into `author`, so reuse the standard authors row
    // (AuthorChip with author-page links + editing). It renders the label as
    // 讲者 for talks and writes edits back to the `speaker:` key (see
    // AppModel.setAuthor), keeping the talk frontmatter schema-correct.
    var rows: [InspectorInfoRow] = [.authors]
    // `date` is indexed into `created`.
    if let date = nonEmpty(entry.created) {
        rows.append(.readOnlyScalar(label: "日期", value: date, copyValue: nil))
    }
    if let transcript = containerContext(for: entry, in: entries)?.children.first {
        rows.append(.linkedScalar(label: "转写", value: displayTitle(for: transcript) ?? AppPresentation.entryTypeLabel(.transcript),
                                  path: transcript.path, copyValue: nil))
    }
    rows.append(.rating)
    return rows
}

private func transcriptRows(for entry: Entry, in entries: [Entry]) -> [InspectorInfoRow] {
    // A transcript's only structured link is back to its talk — the容器②
    // overview of its `talks/<slug>/` folder.
    guard let talk = containerContext(for: entry, in: entries)?.overview else { return [] }
    return [.linkedScalar(label: "讲座", value: displayTitle(for: talk) ?? AppPresentation.entryTypeLabel(.talk),
                          path: talk.path, copyValue: nil)]
}

private func displayTitle(for entry: Entry?) -> String? {
    if let title = nonEmpty(entry?.title) {
        return title
    }
    guard let path = entry?.path else { return nil }
    return (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
}

private func journalDisplayTitle(for entry: Entry?) -> String? {
    nonEmpty(entry?.journal) ?? displayTitle(for: entry)
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func categoryDisplayValue(_ category: String) -> String {
    switch category.lowercased() {
    case "monograph": return String(localized: "专著")
    case "edited volume", "edited-volume": return String(localized: "编著")
    default: return category
    }
}

private func kindDisplayValue(_ kind: String) -> String {
    switch kind.lowercased() {
    case "overview": return String(localized: "概览")
    case "resources": return String(localized: "资源")
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
    case "title":     return String(localized: "标题")
    case "name":      return String(localized: "名称")
    case "authors", "author": return String(localized: "作者")
    case "year":      return String(localized: "年份")
    case "journal":   return String(localized: "期刊")
    case "themes":    return String(localized: "标签")
    case "publisher": return String(localized: "出版")
    case "book":      return String(localized: "书籍")
    case "kind":      return String(localized: "类型")
    case "created":   return String(localized: "创建")
    default:          return field
    }
}
