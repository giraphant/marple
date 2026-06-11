import Foundation

/// The vault's vocabulary as data — which frontmatter fields reference which
/// entity type, and how each entry type is displayed. Built-in defaults mirror
/// what used to be hard-coded across the indexer (speaker/creator column
/// reuse) and the macOS app (TypeIcon). A `vault/schema/schema.yaml` next to
/// the indexed content can override individual keys; see `load(workspaceRoot:)`.
///
/// This is deliberately a *table*, not an engine: semantics live in named
/// Swift code (rules, resolvers); this type only declares the vocabulary.
public struct VaultSchema: Sendable, Equatable {

    /// One frontmatter field that references an entity type, optionally
    /// restricted to entries of a single type (e.g. `speaker` only on `talk`).
    public struct FieldAlias: Sendable, Equatable {
        public let field: String
        public let onlyForType: String?

        public init(_ field: String, onlyForType: String? = nil) {
            self.field = field
            self.onlyForType = onlyForType
        }
    }

    /// SF Symbol name + platform-agnostic tint name for one entry type.
    /// Tint names are mapped to concrete colors by each UI shell.
    public struct TypeDisplay: Sendable, Equatable {
        public let symbol: String
        public let tint: String

        public init(symbol: String, tint: String) {
            self.symbol = symbol
            self.tint = tint
        }
    }

    /// Entity type → ordered list of frontmatter fields that reference it.
    /// Order matters: first present field wins (mirrors the legacy fallback
    /// chain `author ?? authors ?? speaker ?? creator`).
    public var entityAliases: [String: [FieldAlias]]

    /// EntryType rawValue → display. Unknown types fall back to `fallbackDisplay`.
    public var displayByType: [String: TypeDisplay]

    /// Display for `.other` / undeclared types.
    public var fallbackDisplay: TypeDisplay

    public func display(for type: EntryType) -> TypeDisplay {
        displayByType[type.rawValue] ?? fallbackDisplay
    }

    public static let builtin = VaultSchema(
        entityAliases: [
            "author": [
                FieldAlias("author"),
                FieldAlias("authors"),
                FieldAlias("speaker", onlyForType: "talk"),
                FieldAlias("creator", onlyForType: "image"),
            ],
            "journal": [FieldAlias("journal")],
            "topic": [FieldAlias("topics")],
        ],
        displayByType: [
            "paper":      TypeDisplay(symbol: "doc.text", tint: "blue"),
            "book":       TypeDisplay(symbol: "book", tint: "orange"),
            "author":     TypeDisplay(symbol: "person", tint: "purple"),
            "topic":      TypeDisplay(symbol: "square.stack.3d.up", tint: "teal"),
            "journal":    TypeDisplay(symbol: "newspaper", tint: "green"),
            "chapter":    TypeDisplay(symbol: "list.bullet.rectangle", tint: "indigo"),
            "note":       TypeDisplay(symbol: "note.text", tint: "yellow"),
            "image":      TypeDisplay(symbol: "photo", tint: "pink"),
            "talk":       TypeDisplay(symbol: "waveform", tint: "red"),
            "transcript": TypeDisplay(symbol: "text.quote", tint: "brown"),
        ],
        fallbackDisplay: TypeDisplay(symbol: "questionmark.square.dashed", tint: "gray")
    )
}
