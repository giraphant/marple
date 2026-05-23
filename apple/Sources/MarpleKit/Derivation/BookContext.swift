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
    case .chapterSummary: slug = entry.book
    default:              slug = nil
    }
    guard let slug, !slug.isEmpty else { return nil }

    let overview = entries.first { $0.type == .bookOverview && bookSlug($0.path) == slug }
    let chapters = entries
        .filter { $0.type == .chapterSummary && $0.book == slug }
        .sorted { $0.path < $1.path }

    if overview == nil && chapters.isEmpty { return nil }
    return BookContext(slug: slug, overview: overview, chapters: chapters)
}
