import Foundation

/// EPUB-style book context for the reader's 目录 panel: when the open doc is a
/// book-overview or one of its chapters, surface the book's overview plus the
/// ordered chapter list so the reader can jump between them. Mirrors the web
/// `bookContext` memo (src/components/DocView.tsx).
public struct BookContext: Equatable, Sendable {
    public let slug: String
    public let overview: Entry?
    public let chapters: [Entry]   // ordered by path
    public init(slug: String, overview: Entry?, chapters: [Entry]) {
        self.slug = slug
        self.overview = overview
        self.chapters = chapters
    }
}

/// Gather the book `entry` belongs to, or nil when it isn't part of one. The
/// slug comes from the path for a book-overview and from the `book` field for a
/// chapter-summary; the overview is matched by that same path-derived slug and
/// chapters are the chapter-summaries carrying it, ordered by path.
public func bookContext(for entry: Entry, in entries: [Entry]) -> BookContext? {
    let slug: String?
    switch entry.type {
    case .bookOverview:   slug = bookSlug(entry.path)
    case .chapterSummary: slug = chapterBookSlug(entry)
    default:              slug = nil
    }
    guard let slug, !slug.isEmpty else { return nil }

    let overview = entries.first { $0.type == .bookOverview && bookSlug($0.path) == slug }
    let chapters = entries
        .filter { $0.type == .chapterSummary && chapterBookSlug($0) == slug }
        .sorted { $0.path < $1.path }

    if overview == nil && chapters.isEmpty { return nil }
    return BookContext(slug: slug, overview: overview, chapters: chapters)
}

public func citationEntry(for entry: Entry, in entries: [Entry]) -> Entry? {
    switch entry.type {
    case .paperAnalysis, .bookOverview:
        return entry
    case .chapterSummary:
        if hasCitationMetadata(entry) { return entry }
        return bookContext(for: entry, in: entries)?.overview
    default:
        return nil
    }
}

public func pdfEntry(for entry: Entry, in entries: [Entry]) -> Entry? {
    if entry.hasPDF, entry.pdfSlug?.isEmpty == false { return entry }
    if entry.type == .chapterSummary {
        guard let overview = bookContext(for: entry, in: entries)?.overview else { return nil }
        if overview.hasPDF, overview.pdfSlug?.isEmpty == false { return overview }
    }
    return nil
}

public func sourceSlugCandidates(for entry: Entry, in entries: [Entry]) -> [String] {
    var slugs: [String] = []
    appendSlug(entry.pdfSlug, to: &slugs)
    if entry.type == .chapterSummary, let overview = bookContext(for: entry, in: entries)?.overview {
        appendSlug(overview.pdfSlug, to: &slugs)
    }
    return slugs
}

private func appendSlug(_ slug: String?, to slugs: inout [String]) {
    guard let slug, !slug.isEmpty, !slugs.contains(slug) else { return }
    slugs.append(slug)
}

private func chapterBookSlug(_ entry: Entry) -> String? {
    entry.book ?? bookSlug(entry.path)
}

private func hasCitationMetadata(_ entry: Entry) -> Bool {
    if !entry.author.isEmpty { return true }
    return [entry.year, entry.source, entry.doi].contains { value in
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
