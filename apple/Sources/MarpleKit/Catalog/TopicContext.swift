import Foundation

// MARK: - TopicContext (QUA-189)
//
// Topic counterpart to BookContext. A topic directory (`vault/topics/<slug>/`)
// holds an `overview` page plus zero or more `resources` (and other) pages —
// all `type=topic`, distinguished only by `kind`. This mirrors a book's
// overview + chapters so the inspector can offer the same EPUB-style "本专题"
// navigation. The discriminator is `kind` (not type, as with book/chapter):
// the `kind=overview` page is the anchor; every other topic page in the slug
// is a navigable sub-page.

/// EPUB-style topic context: the topic's overview anchor plus its ordered
/// sub-pages (resources etc.), so the reader can jump between them.
public struct TopicContext: Equatable, Sendable {
    public let slug: String
    public let overview: Entry?
    public let pages: [Entry]   // non-overview topic pages, ordered by path
    public init(slug: String, overview: Entry?, pages: [Entry]) {
        self.slug = slug
        self.overview = overview
        self.pages = pages
    }
}

/// Gather the topic `entry` belongs to, or nil when it isn't a topic page or has
/// no sibling sub-pages to navigate between. The slug comes from the path; the
/// overview is the `kind=overview` page (falling back to the path-first page when
/// none is tagged), and `pages` are the remaining topic pages ordered by path.
///
/// Returns nil for a single-page topic (overview only): a "本专题" panel that
/// lists just the page you're already on would be noise. This is the one
/// deliberate deviation from `bookContext`, which surfaces even a chapterless
/// book.
public func topicContext(for entry: Entry, in entries: [Entry]) -> TopicContext? {
    guard entry.type == .topic, let slug = topicSlug(entry.path) else { return nil }

    let topicPages = entries.filter { $0.type == .topic && topicSlug($0.path) == slug }
    let overview = topicPages.first { ($0.kind ?? "") == "overview" }
        ?? topicPages.min { $0.path < $1.path }
    let pages = topicPages
        .filter { $0.path != overview?.path }
        .sorted { $0.path < $1.path }

    guard !pages.isEmpty else { return nil }
    return TopicContext(slug: slug, overview: overview, pages: pages)
}
