import Foundation

/// QUA-218: the common contract for "something in the vault changed, refresh".
/// The Mac's `VaultWatcher` (FSEvents) implements it; boot and the CLI surface
/// trigger the same refresh through Catalog directly. Implementers debounce/
/// coalesce as they see fit (VaultWatcher keeps its 0.4s Coalescer), then call
/// the injected `onChange`, which routes to `catalog.refresh(model.refreshBody)`.
public protocol VaultChangeSource: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}
