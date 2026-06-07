import Foundation

public enum Pane: Hashable, Sendable, Codable {
    case type(EntryType)
    case themesIndex
    case theme(String)
    case trash
}

/// Base subset for a pane, before filter/sort. `.themesIndex` and `.trash` are
/// not list-of-entry views.
public func entriesForPane(_ pane: Pane, in entries: [Entry]) -> [Entry] {
    switch pane {
    // QUA-189: the 专题 bucket shows one row per topic (its overview), the way
    // the 图书 bucket shows books not chapters. Resources/other sub-pages are
    // reached through the inspector's 本专题 navigation instead of flattening here.
    case .type(.topic):    return topicBrowseSubset(entries)
    case .type(let t):     return entries.filter { $0.type == t }
    case .theme(let name): return entries.filter { $0.themes.contains(name) }
    case .themesIndex:     return []
    case .trash:           return []
    }
}

/// One entry per topic slug — its overview page — collapsing resources/other
/// sub-pages out of the browse list (QUA-189). Overview is the `kind=overview`
/// page, falling back to the path-first page when none is tagged. A topic page
/// whose path yields no slug is kept as-is (defensive; topics live under
/// `vault/topics/<slug>/`, so this shouldn't occur). Order is irrelevant — the
/// caller re-sorts; the sidebar count reuses this so count == list length.
public func topicBrowseSubset(_ entries: [Entry]) -> [Entry] {
    var bySlug: [String: [Entry]] = [:]
    var slugless: [Entry] = []
    for e in entries where e.type == .topic {
        if let slug = topicSlug(e.path) {
            bySlug[slug, default: []].append(e)
        } else {
            slugless.append(e)
        }
    }
    var result = slugless
    for (_, pages) in bySlug {
        let overview = pages.first { ($0.kind ?? "") == "overview" }
            ?? pages.min { $0.path < $1.path }
        if let overview { result.append(overview) }
    }
    return result
}
