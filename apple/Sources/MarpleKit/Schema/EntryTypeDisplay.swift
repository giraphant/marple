public extension VaultSchema {
    /// The schema in effect for display lookups. Updated by the app shell on
    /// each `loadIndex()` call (vault open and file-watcher reloads); defaults
    /// to builtin so views render sensibly before any vault is open. The app
    /// is single-vault — `workspaceRoot` is fixed for the process lifetime, so
    /// there is no vault-switch path to handle. Main-actor because every
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
