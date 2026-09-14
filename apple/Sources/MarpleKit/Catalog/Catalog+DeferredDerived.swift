import Foundation

// Deferred (background) derive：relationGraph / searchIndex，独立 derivedGeneration。
// Split out of Catalog.swift (QUA-218 PR3a Task 8); QUA-221 threads the active
// VaultSchema into RelationGraph.build so rule③ path references are table-driven.
extension Catalog {
    /// Build the heavy derived caches (relation graph, search index) on a
    /// background task and publish them on the main actor when done. If
    /// `entries` changes during a build, discard that result and build the latest
    /// snapshot next. One worker bounds memory during refresh bursts; cancelling
    /// an outer task alone would leave all its detached builds running.
    func scheduleDeferredDerivedRebuild() {
        derivedGeneration &+= 1
        guard deferredDerivedTask == nil else { return }
        deferredDerivedTask = Task { [weak self] in
            while let self {
                let generation = self.derivedGeneration
                let snapshot = self.entries
                let schema = VaultSchema.active
                let graph = await Task.detached(priority: .utility) {
                    RelationGraph.build(snapshot, schema: schema)
                }.value
                guard generation == self.derivedGeneration else { continue }
                // Publish on the next runloop tick to avoid NSTableView reentrant
                // delegate calls. A newer snapshot can still veto this block.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.derivedGeneration == generation else { return }
                    self.relationGraph = graph
                    if self.hasOpenDerivedInput {
                        self.recomputeOpenDerivedFromStoredInput()
                    }
                }
                // The search index can take seconds. Make the ready graph
                // available first so navigation doesn't keep rebuilding it.
                let search = await Task.detached(priority: .utility) {
                    buildSearchIndex(snapshot)
                }.value
                guard generation == self.derivedGeneration else { continue }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.derivedGeneration == generation else { return }
                    self.searchIndex = search
                }
                self.deferredDerivedTask = nil
                return
            }
        }
    }
}
