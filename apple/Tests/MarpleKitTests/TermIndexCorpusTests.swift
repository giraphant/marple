import Foundation
import Testing
@testable import MarpleKit

/// Opt-in corpus check: reads the supplied vault, writes only a disposable /tmp
/// database, and reports timing/provenance for review without touching live indexes.
@Suite("TermIndex corpus")
struct TermIndexCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARPLE_TERMS_CORPUS"] != nil))
    func existingVault() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["MARPLE_TERMS_CORPUS"])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("terms-corpus-\(UUID().uuidString)")
        let index = TermIndex(workspaceRoot: root, databasePath: output.appendingPathComponent("terms.sqlite").path)
        let start = Date()
        let first = try await index.refresh()
        let built = Date()
        #expect(first.relations > 0)
        #expect(try await index.refresh() == first)
        let refreshed = Date()
        print("TERMS_CORPUS database=\(index.databasePath)")
        print("TERMS_CORPUS documents=\(first.scannedDocuments) sources=\(first.sourceDocuments) terms=\(first.terms) relations=\(first.relations)")
        print("TERMS_CORPUS build_seconds=\(built.timeIntervalSince(start)) unchanged_seconds=\(refreshed.timeIntervalSince(built))")
        for (chinese, english) in [("具身性", "embodiment"), ("惯习", "habitus"),
            ("能动性", "agency"), ("异化", "alienation"), ("社会资本", "social capital"), ("象征暴力", "symbolic violence")] {
            let matches = try await index.lookup(chinese)
            let match = try #require(matches.first { TermParser.key($0.term) == english })
            let reverse = try await index.lookup(english)
            #expect(reverse.contains { $0.term == chinese })
            let source = try #require(match.sources.first)
            let text = try String(contentsOfFile: root + "/" + source.path, encoding: .utf8)
            let lines = text.components(separatedBy: .newlines)
            #expect(lines.indices.contains(source.line - 1))
            #expect(lines[source.line - 1].lowercased().contains(english))
            print("TERMS_CORPUS \(chinese) -> \(match.term) sources=\(match.sources.count) example=\(source.path):\(source.line)")
            let queries = try await index.expandedQueries(chinese, depth: 2)
            print("TERMS_CORPUS expansion=\(chinese) count=\(queries.count) queries=\(queries)")
        }
    }
}
