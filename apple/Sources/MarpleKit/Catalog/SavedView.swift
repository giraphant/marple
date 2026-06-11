import Foundation

/// A named, persisted (filter + sort) over the whole vault — a sidebar smart
/// folder (QUA-127, NetNewsWire smart-feed style). App state, not index data:
/// lives in `PersistedState`, never SQLite. Selected via `Pane.savedView(id)`;
/// the list pipeline applies the view's own clauses/sorts instead of the
/// global browse controls.
public struct SavedView: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var clauses: [FilterClause]
    public var match: FilterMatch
    public var sorts: [SortClause]

    public init(id: UUID = UUID(), name: String, clauses: [FilterClause],
                match: FilterMatch = .all, sorts: [SortClause] = []) {
        self.id = id
        self.name = name
        self.clauses = clauses
        self.match = match
        self.sorts = sorts
    }
}
