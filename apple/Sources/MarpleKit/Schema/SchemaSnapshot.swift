import Foundation

/// Read-only view of the vault's self-describing schema snapshot, written by the
/// Quasi plugin to `<workspaceRoot>/.quasi/schema.json` (contract
/// `quasi-schema-snapshot.v1`, see the plugin's `scripts/audit/emit_schema.py`).
///
/// Marple is a pure consumer: it never writes this file and never runs Python.
/// When the file is absent, unreadable, malformed, or carries a contract version
/// this build does not understand, `load` returns nil and every conformance
/// consumer goes dark — the UI is then identical to a vault that was never
/// audited (graceful degradation). The vault is the source of truth; Marple does
/// not compensate for a missing or stale snapshot.
public struct SchemaSnapshot: Decodable, Sendable, Equatable {
    /// The contract version string declared by the snapshot file.
    public let version: String

    /// Per-type required frontmatter field names, keyed by canonical type
    /// (`paper`, `book`, …). Values are the *schema's* own field names
    /// (e.g. `authors`, `name`), excluding the tautological `type` discriminator.
    public let requiredByType: [String: [String]]

    private enum CodingKeys: String, CodingKey { case version, types }
    private struct TypeSpec: Decodable { let required: [String] }

    public init(version: String = SchemaSnapshot.supportedVersion,
                requiredByType: [String: [String]]) {
        self.version = version
        self.requiredByType = requiredByType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        let types = try c.decode([String: TypeSpec].self, forKey: .types)
        requiredByType = types.mapValues { $0.required }
    }
}

public extension SchemaSnapshot {
    /// Snapshot location relative to the workspace root.
    static let relativePath = ".quasi/schema.json"

    /// The single contract version this build models.
    static let supportedVersion = "quasi-schema-snapshot.v1"

    /// Load and version-gate the snapshot under `<workspaceRoot>/.quasi/schema.json`.
    ///
    /// Returns nil in every "can't trust it" case — file absent, unreadable,
    /// malformed JSON, or an unrecognized contract `version` — so the caller
    /// treats the vault as having no schema opinion rather than guessing.
    static func load(workspaceRoot: String) -> SchemaSnapshot? {
        guard !workspaceRoot.isEmpty else { return nil }
        let url = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(SchemaSnapshot.self, from: data),
              snapshot.version == supportedVersion
        else { return nil }
        return snapshot
    }
}
