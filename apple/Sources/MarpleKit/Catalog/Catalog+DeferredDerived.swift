import Foundation

// Deferred (background) derive：relationGraph / searchIndex，独立 derivedGeneration。
// Split out of Catalog.swift (QUA-218 PR3a Task 8); QUA-221 threads the active
// VaultSchema into RelationGraph.build so rule③ path references are table-driven.
extension Catalog {
    /// Build the heavy derived caches (relation graph, search index) on a
    /// background task and publish them on the main actor when done. If
    /// `entries` changes again before this task completes, the in-flight task
    /// is cancelled and stale dispatch blocks are vetoed by generation counter
    /// — only the latest snapshot wins.
    func scheduleDeferredDerivedRebuild(entries: [Entry]) {
        deferredDerivedTask?.cancel()
        derivedGeneration &+= 1
        let generation = derivedGeneration
        let snapshot = entries
        // Capture the active schema on the main actor; the detached build below
        // can't reach `VaultSchema.active` (@MainActor). VaultSchema is Sendable.
        let schema = VaultSchema.active
        deferredDerivedTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let graph = RelationGraph.build(snapshot, schema: schema)
                let search = buildSearchIndex(snapshot)
                return (graph, search)
            }.value
            if Task.isCancelled { return }
            // Hop to the next main-runloop tick (not MainActor.run, which can
            // run synchronously inside the current render pass and triggered an
            // NSTableView reentrant-delegate warning when @Observable
            // invalidation cascaded back into the table mid-render).
            //
            // DispatchQueue.main.async can't be cancelled, so guard the
            // assignment with the generation counter: any newer rebuild bumps
            // `derivedGeneration` and this stale block becomes a no-op.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.derivedGeneration == generation else { return }
                self.relationGraph = result.0
                self.searchIndex = result.1
                if self.hasOpenDerivedInput {
                    self.recomputeOpenDerivedFromStoredInput()
                }
            }
        }
    }
}
