public extension VaultSchema {
    /// The schema in effect for display lookups. Set once by the app shell
    /// when a vault opens (AppModel.loadIndex); defaults to builtin so views
    /// render sensibly before any vault is open. Main-actor because every
    /// consumer is a view; the indexer carries its own copy instead.
    @MainActor static var active: VaultSchema = .builtin
}

/// Display attributes for entry types, read from the active schema.
/// Platform-agnostic strings — each UI shell maps `tintName` to a color.
@MainActor
public extension EntryType {
    var symbolName: String { VaultSchema.active.display(for: self).symbol }
    var tintName: String { VaultSchema.active.display(for: self).tint }
}
