import Foundation
import Testing
@testable import MarpleKit

/// Diagnostic workload for TSan. A shared immutable input exercises COW reads;
/// each invocation must build a complete independent postings dictionary.
@Suite struct DerivedRebuildStressTests {
    private static func entries(_ count: Int) -> [Entry] {
        (0..<count).map { i in
            Entry(path: "vault/papers/\(i).md", type: .paper,
                  title: "Literature \(i) 语言与社会", author: ["Author \(i % 31)"],
                  year: "2026", ratingScore: 0, themes: ["研究", "history"], topics: [],
                  preview: String(repeating: "Evidence knowledge interpretation \(i). ", count: 16),
                  hasPDF: false)
        }
    }

    @Test func concurrentSearchBuildsKeepIndependentPostings() async {
        let snapshot = Self.entries(10_000)
        let tasks = (0..<8).map { _ in
            Task.detached(priority: .utility) { buildSearchIndex(snapshot) }
        }
        for task in tasks {
            let index = await task.value
            #expect(index.documents.count == 10_000)
            // Hand-derived: every document has the title token Literature.
            #expect(searchDocuments(index, "Literature").count == 10_000)
            #expect(index.postings.values.allSatisfy { posting in
                zip(posting, posting.dropFirst()).allSatisfy { $0 < $1 }
            })
        }
    }

    @MainActor
    @Test func overlappingScheduledBuildsPublishLatestSnapshot() async throws {
        let catalog = Catalog()
        let snapshot = Self.entries(10_000)
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<8 {
            catalog.scheduleDeferredDerivedRebuild(entries: snapshot)
            if let task = catalog.deferredDerivedTask { tasks.append(task) }
            // Let each detached child start before cancelling its parent.
            try await Task.sleep(for: .milliseconds(10))
        }
        catalog.scheduleDeferredDerivedRebuild(entries: Array(snapshot.prefix(3)))
        if let task = catalog.deferredDerivedTask { tasks.append(task) }
        for task in tasks { await task.value }
        // Publication is deliberately queued onto the next main dispatch tick.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(catalog.searchIndex.documents.map(\.entry.path) == [
            "vault/papers/0.md", "vault/papers/1.md", "vault/papers/2.md"
        ])
    }
}
