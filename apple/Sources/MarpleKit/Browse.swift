import Foundation

public enum Pane: Hashable, Sendable {
    case type(EntryType)
    case themesIndex
    case theme(String)
}

/// Base subset for a pane, before filter/sort. `.themesIndex` is not a list view.
public func entriesForPane(_ pane: Pane, in entries: [Entry]) -> [Entry] {
    switch pane {
    case .type(let t):     return entries.filter { $0.type == t }
    case .theme(let name): return entries.filter { $0.themes.contains(name) }
    case .themesIndex:     return []
    }
}
