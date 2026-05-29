import Foundation

/// Outcome of checking one entry against the vault schema snapshot.
public struct ConformanceResult: Sendable, Equatable {
    /// Schema field names (the snapshot's own names, e.g. `authors`, `name`) that
    /// are required for this entry's type but missing or empty. Empty → conforming.
    public let missingRequired: [String]

    public init(missingRequired: [String]) {
        self.missingRequired = missingRequired
    }

    public var isConforming: Bool { missingRequired.isEmpty }
}

/// Checks a single `Entry` against a `SchemaSnapshot`. Pure logic, no I/O — the
/// snapshot is loaded once by the caller and handed in. This is the auxiliary,
/// pluggable seam: nothing in the normal list / inspector path depends on it, and
/// when no snapshot exists the consumers simply never call `check`.
public enum VaultConformance {

    /// Check one entry against the snapshot.
    ///
    /// Returns nil when the snapshot has *no opinion* on this entry — i.e. the
    /// entry's type `rawValue` is absent from the snapshot's `types`. That covers
    /// experimental `.other` kinds whose raw string the producing Quasi version did
    /// not emit. (If a snapshot *does* name a type Marple happens to carry as
    /// `.other`, it is checked like any other; field-level degradation below keeps
    /// unmodeled fields from producing false "missing".) A nil result means "do not
    /// flag" — consumers render exactly as they would with no snapshot at all.
    ///
    /// A non-nil result lists the required field names that are absent or empty.
    /// "Required AND non-empty" is Marple's presentation policy layered on the
    /// snapshot's required-*presence*; it stays faithful because every required
    /// field in the Quasi schema is itself value-constrained non-empty (Title /
    /// Name / ShortString are `min_length>=2`, required lists `min_length=1`). See
    /// `emit_schema.py`'s docstring — the two must not silently diverge.
    public static func check(_ entry: Entry, against snapshot: SchemaSnapshot) -> ConformanceResult? {
        guard let required = snapshot.requiredByType[entry.type.rawValue] else {
            return nil
        }
        let missing = required.filter { !isPresent($0, in: entry) }
        return ConformanceResult(missingRequired: missing)
    }

    /// Whether a schema field name is present-and-non-empty in the entry.
    ///
    /// Maps each *schema* field name onto Marple's `Entry` accessor. The indexer
    /// folds an author document's `name` into `title` (see `buildIndexedEntry`),
    /// so author's required `name` is satisfied by a non-empty `title`; likewise
    /// `author`/`authors` both land in the `author` array.
    ///
    /// A field name Marple does not model returns `true` (not flagged): Marple
    /// cannot verify a field it does not carry, so it stays silent rather than
    /// reporting a false "missing" if a newer Quasi schema adds a field this build
    /// predates. This is field-level graceful degradation, parallel to the
    /// type-level "no opinion" above.
    private static func isPresent(_ field: String, in entry: Entry) -> Bool {
        switch field {
        case "title", "name":   return nonEmpty(entry.title)
        case "authors", "author": return !entry.author.isEmpty
        case "themes":          return !entry.themes.isEmpty
        case "year":            return nonEmpty(entry.year)
        case "publisher":       return nonEmpty(entry.publisher)
        case "book":            return nonEmpty(entry.book)
        case "kind":            return nonEmpty(entry.kind)
        case "journal":         return nonEmpty(entry.journal)
        case "created":         return nonEmpty(entry.created)
        case "doi":             return nonEmpty(entry.doi)
        case "isbn":            return nonEmpty(entry.isbn)
        case "category":        return nonEmpty(entry.category)
        case "annotates":       return nonEmpty(entry.annotates)
        case "source":          return nonEmpty(entry.source)
        default:                return true
        }
    }

    private static func nonEmpty(_ s: String?) -> Bool {
        guard let s else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
