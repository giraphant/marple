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

public extension VaultSchema {

    /// Schema override location relative to the workspace root. Lives inside
    /// `vault/schema/` (the user's synced data, shared territory with quasi;
    /// the vault root keeps no loose files) — NOT `.marple/`, which is a
    /// disposable cache rebuilt via `rm -rf`.
    static let relativePath = "vault/schema/schema.yaml"

    /// Built-in defaults overlaid by `vault/schema/schema.yaml` when present.
    ///
    /// Override granularity is per top-level entity / display key: declaring
    /// `entities.author` replaces the author alias list wholesale; keys not
    /// mentioned keep their builtin value. Malformed YAML or unreadable file
    /// → builtin (graceful degradation, same philosophy as SchemaSnapshot).
    static func load(workspaceRoot: String) -> VaultSchema {
        guard !workspaceRoot.isEmpty else { return .builtin }
        let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .builtin }
        return builtin.applying(overrides: YamlFrontmatter.parseMapping(text))
    }

    /// Apply a parsed YAML mapping onto self. Unrecognized or ill-typed keys
    /// are ignored (keep the existing value) rather than failing the whole
    /// file. An empty `fields` list is ignored (keeps the existing aliases);
    /// remove the entity key entirely instead.
    func applying(overrides: [(String, YamlValue)]) -> VaultSchema {
        var result = self
        for (key, value) in overrides {
            switch key {
            case "entities":
                guard case .mapping(let entities) = value else { continue }
                for (entity, spec) in entities {
                    guard case .mapping(let fields) = spec,
                          let fieldsValue = fields.first(where: { $0.0 == "fields" })?.1,
                          case .sequence(let items) = fieldsValue else { continue }
                    let aliases = items.compactMap { Self.alias(from: $0) }
                    if !aliases.isEmpty { result.entityAliases[entity] = aliases }
                }
            case "display":
                guard case .mapping(let types) = value else { continue }
                for (type, spec) in types {
                    guard case .mapping(let pairs) = spec,
                          case .string(let symbol)? = pairs.first(where: { $0.0 == "symbol" })?.1,
                          case .string(let tint)? = pairs.first(where: { $0.0 == "tint" })?.1
                    else { continue }
                    result.displayByType[type] = TypeDisplay(symbol: symbol, tint: tint)
                }
            default:
                continue
            }
        }
        return result
    }

    /// A fields item is either a plain string (`- author`) or a mapping
    /// (`- {field: speaker, type: talk}`).
    private static func alias(from value: YamlValue) -> FieldAlias? {
        switch value {
        case .string(let s):
            return FieldAlias(s)
        case .mapping(let pairs):
            guard case .string(let f)? = pairs.first(where: { $0.0 == "field" })?.1 else { return nil }
            if case .string(let t)? = pairs.first(where: { $0.0 == "type" })?.1 {
                return FieldAlias(f, onlyForType: t)
            }
            return FieldAlias(f)
        default:
            return nil
        }
    }
}
