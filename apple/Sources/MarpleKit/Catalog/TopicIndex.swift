import Foundation

// MARK: - TopicIndex (QUA-137)
//
// Topic-membership is a bidirectional join introduced with quasi schema 0.4.0:
//   - a topic page (type=topic) lives at `vault/topics/<slug>/…` and is identified
//     by its directory slug + H1 (the singular `topic` frontmatter field is gone);
//   - paper/book/chapter/author entities declare `topics: [slug]` to say which
//     topic corpora they belong to (mirrors `themes`).
// Marple derives both directions in memory from the loaded `[Entry]` — there is no
// browse pane, so no SQL `entry_topics` table is needed.

/// First path component after `vault/topics/` — the topic's directory slug, which
/// is its identity under schema 0.4.0. Mirrors `bookSlug`. Returns nil for paths
/// outside `vault/topics/` or with an empty first component.
public func topicSlug(_ rel: String) -> String? {
    guard rel.hasPrefix("vault/topics/") else { return nil }
    let rest = String(rel.dropFirst("vault/topics/".count))
    let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init)
    guard let slug = first, !slug.isEmpty else { return nil }
    return slug
}

/// Bidirectional topic-membership index.
public struct TopicMembership: Sendable, Equatable {
    /// topic slug → entities that declare membership via `topics: [slug]`.
    public var membersBySlug: [String: [Entry]]
    /// topic slug → the topic page entry for that slug (first by path wins, so a
    /// `00-overview.md` is preferred over a sibling `01-resources.md`).
    public var topicEntryBySlug: [String: Entry]

    public init(membersBySlug: [String: [Entry]] = [:],
                topicEntryBySlug: [String: Entry] = [:]) {
        self.membersBySlug = membersBySlug
        self.topicEntryBySlug = topicEntryBySlug
    }
}

/// Build the bidirectional topic-membership index over all entries.
public func buildTopicMembership(_ entries: [Entry]) -> TopicMembership {
    var membersBySlug: [String: [Entry]] = [:]
    var topicEntryBySlug: [String: Entry] = [:]
    for e in entries {
        if e.type == .topic, let slug = topicSlug(e.path) {
            if let current = topicEntryBySlug[slug] {
                if e.path < current.path { topicEntryBySlug[slug] = e }
            } else {
                topicEntryBySlug[slug] = e
            }
        }
        for slug in e.topics where !slug.isEmpty {
            membersBySlug[slug, default: []].append(e)
        }
    }
    return TopicMembership(membersBySlug: membersBySlug, topicEntryBySlug: topicEntryBySlug)
}

/// Display title for a topic slug: the topic page's resolved title (H1 /
/// frontmatter), or nil when no topic page for that slug is loaded. Used to turn
/// a member entity's raw `topics:` slugs into readable names in the inspector.
public func topicDisplayTitle(forSlug slug: String, in entries: [Entry]) -> String? {
    let topic = entries
        .filter { $0.type == .topic && topicSlug($0.path) == slug }
        .min { $0.path < $1.path }
    let title = topic?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (title?.isEmpty == false) ? title : nil
}
