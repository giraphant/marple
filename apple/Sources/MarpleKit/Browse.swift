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
    case .type(let t):     return entries.filter { $0.type == t }
    case .theme(let name): return entries.filter { $0.themes.contains(name) }
    case .themesIndex:     return []
    case .trash:           return []
    }
}
