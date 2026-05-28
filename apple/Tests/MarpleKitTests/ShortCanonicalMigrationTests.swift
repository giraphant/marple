import Testing
import Foundation
@testable import MarpleKit

// QUA-119 forward-only behavior tests.
//
// Vault-content migration is handled out-of-band (delete .marple/, let
// buildFull rebuild). What lives here is the *forward-looking* behavior
// the issue introduces: the unknown-type diagnostic and the short-form
// CLI digest contract.

// MARK: - Unknown-type diagnostic

@Suite("QUA-119: unknown-type diagnostic")
struct UnknownTypeReporterTests {

    /// Run `work` under a task-local override that captures every reported
    /// unknown-type incident. Because the override is `@TaskLocal`, parallel
    /// `@Test` cases each see their own capture.
    private func capturingReports(_ work: () -> Void) -> [UnknownTypeReport] {
        let collector = Collector()
        UnknownTypeReporter.$override.withValue({ report in
            collector.append(report)
        }) {
            work()
        }
        return collector.reports
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _reports: [UnknownTypeReport] = []
        var reports: [UnknownTypeReport] {
            lock.lock(); defer { lock.unlock() }
            return _reports
        }
        func append(_ r: UnknownTypeReport) {
            lock.lock(); defer { lock.unlock() }
            _reports.append(r)
        }
    }

    @Test("legacy long type surfaces a report with its raw value + path")
    func legacyLongFormReports() {
        let md = """
        ---
        type: paper-analysis
        title: Stale
        ---
        Body.
        """
        let reports = capturingReports {
            _ = buildIndexedEntry(
                text: md,
                rel: "vault/papers/stale.md",
                fileStem: "stale",
                sourceSlugs: [],
                mtimeMs: nil
            )
        }
        #expect(reports == [
            UnknownTypeReport(path: "vault/papers/stale.md", rawType: "paper-analysis"),
        ])
    }

    @Test("'A' sentinel and unknown experimental types both report")
    func sentinelAndExperimentalReport() {
        let docs: [(String, String)] = [
            ("vault/n/a.md", "A"),
            ("vault/n/r.md", "topic-reading-list"),
        ]
        let reports = capturingReports {
            for (path, type) in docs {
                let md = "---\ntype: \(type)\ntitle: x\n---\nBody."
                _ = buildIndexedEntry(text: md, rel: path, fileStem: "x",
                                      sourceSlugs: [], mtimeMs: nil)
            }
        }
        #expect(reports.count == 2)
        #expect(reports.map(\.rawType) == ["A", "topic-reading-list"])
        #expect(reports.map(\.path) == ["vault/n/a.md", "vault/n/r.md"])
    }

    @Test("recognized short types produce no report")
    func recognizedTypesQuiet() {
        let reports = capturingReports {
            for short in ["paper", "book", "chapter", "author",
                          "topic", "journal", "note", "image"] {
                let md = "---\ntype: \(short)\ntitle: x\n---\nBody."
                _ = buildIndexedEntry(text: md, rel: "vault/x/\(short).md",
                                      fileStem: short,
                                      sourceSlugs: [], mtimeMs: nil)
            }
        }
        #expect(reports.isEmpty)
    }
}

// MARK: - CLI digest short forms

@Suite("QUA-119: CLI EntryDigest emits short forms")
struct CLIShortFormDigestTests {

    @Test("EntryDigest carries the EntryType rawValue verbatim — short form")
    func entryDigestUsesShortRawValue() {
        for short in ["paper", "book", "chapter", "author",
                      "topic", "journal", "note", "image"] {
            let t = EntryType(rawValue: short)
            let digest = EntryDigest(path: "vault/x/\(short).md",
                                     title: "x", type: t.rawValue,
                                     themes: [], author: [],
                                     year: nil, mtime: nil)
            #expect(digest.type == short)
        }
    }
}
