import Foundation
import Testing
@testable import MarpleKit

@Suite struct SchemaSnapshotTests {

    /// A snapshot matching the live `quasi-schema-snapshot.v1` contract.
    private static func snapshotJSON(version: String = "quasi-schema-snapshot.v1") -> String {
        """
        {
          "version": "\(version)",
          "generated_at": "2026-05-28T00:00:00Z",
          "schema_version": "0.4.0",
          "types": {
            "author":  {"required": ["name"]},
            "paper":   {"required": ["title", "authors", "year", "journal", "themes"]},
            "book":    {"required": ["title", "authors", "year", "publisher"]},
            "topic":   {"required": ["kind"]}
          }
        }
        """
    }

    private func write(_ contents: String, into dir: URL) throws {
        let quasi = dir.appendingPathComponent(".quasi")
        try FileManager.default.createDirectory(at: quasi, withIntermediateDirectories: true)
        try contents.write(to: quasi.appendingPathComponent("schema.json"),
                           atomically: true, encoding: .utf8)
    }

    private func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marple-conformance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadsRequiredFieldsByType() throws {
        let dir = try tmpDir()
        try write(Self.snapshotJSON(), into: dir)
        let snap = try #require(SchemaSnapshot.load(workspaceRoot: dir.path))
        #expect(snap.version == "quasi-schema-snapshot.v1")
        #expect(snap.requiredByType["author"] == ["name"])
        #expect(snap.requiredByType["paper"] == ["title", "authors", "year", "journal", "themes"])
        #expect(snap.requiredByType["book"] == ["title", "authors", "year", "publisher"])
    }

    @Test func missingFileReturnsNil() throws {
        let dir = try tmpDir()  // no .quasi/schema.json written
        #expect(SchemaSnapshot.load(workspaceRoot: dir.path) == nil)
    }

    @Test func emptyWorkspaceRootReturnsNil() {
        // Stub-backed tests construct AppModel with workspaceRoot "" — loading must
        // stay dark rather than resolving `.quasi/schema.json` against an
        // unintended base directory.
        #expect(SchemaSnapshot.load(workspaceRoot: "") == nil)
    }

    @Test func malformedJSONReturnsNil() throws {
        let dir = try tmpDir()
        try write("{ not json", into: dir)
        #expect(SchemaSnapshot.load(workspaceRoot: dir.path) == nil)
    }

    @Test func unrecognizedContractVersionReturnsNil() throws {
        let dir = try tmpDir()
        try write(Self.snapshotJSON(version: "quasi-schema-snapshot.v2"), into: dir)
        #expect(SchemaSnapshot.load(workspaceRoot: dir.path) == nil)
    }
}

@Suite struct VaultConformanceTests {

    /// The full eight-type required-field contract, locked to match quasi's
    /// `test_schema_snapshot.py::EXPECTED_REQUIRED`. If quasi adds/changes a
    /// required field, both sides must move together — this keeps the Marple
    /// field-name mapping honest for every canonical type, not just the four
    /// used in earlier cases.
    private static let snapshot = SchemaSnapshot(requiredByType: [
        "author":  ["name"],
        "book":    ["title", "authors", "year", "publisher"],
        "chapter": ["title", "authors", "year", "book"],
        "image":   ["title"],
        "journal": ["kind", "journal"],
        "note":    ["title", "created"],
        "paper":   ["title", "authors", "year", "journal", "themes"],
        "topic":   ["kind"],
    ])

    private func entry(_ type: EntryType, title: String? = nil, author: [String] = [],
                       year: String? = nil, themes: [String] = [], journal: String? = nil,
                       publisher: String? = nil, kind: String? = nil,
                       book: String? = nil,
                       created: String? = nil) -> Entry {
        Entry(path: "vault/x.md", type: type, title: title, author: author, year: year,
              ratingScore: 0, themes: themes, preview: "", hasPDF: false,
              book: book, kind: kind, journal: journal,
              publisher: publisher, created: created)
    }

    @Test func conformingPaperHasNoMissing() {
        let e = entry(.paper, title: "T", author: ["A"], year: "2020",
                      themes: ["t"], journal: "J")
        let result = VaultConformance.check(e, against: Self.snapshot)
        #expect(result?.isConforming == true)
        #expect(result?.missingRequired == [])
    }

    @Test func paperReportsMissingInSchemaOrder() {
        let e = entry(.paper, title: "T", author: [], year: nil, themes: [], journal: "J")
        let result = VaultConformance.check(e, against: Self.snapshot)
        // schema order: title, authors, year, journal, themes
        #expect(result?.missingRequired == ["authors", "year", "themes"])
    }

    @Test func emptyAndWhitespaceScalarsCountAsMissing() {
        let e = entry(.book, title: "   ", author: ["A"], year: "2020", publisher: "")
        let result = VaultConformance.check(e, against: Self.snapshot)
        #expect(result?.missingRequired == ["title", "publisher"])
    }

    @Test func authorNameSatisfiedByFoldedTitle() {
        // The indexer folds an author doc's `name` into `title`; a non-empty
        // title must satisfy the required `name` field.
        let e = entry(.author, title: "Aryn Martin")
        #expect(VaultConformance.check(e, against: Self.snapshot)?.isConforming == true)
    }

    @Test func chapterReportsMissingBook() {
        let e = entry(.chapter, title: "Ch", author: ["A"], year: "2020")
        #expect(VaultConformance.check(e, against: Self.snapshot)?.missingRequired == ["book"])
    }

    @Test func conformingChapterHasNoMissing() {
        let e = entry(.chapter, title: "Ch", author: ["A"], year: "2020", book: "B")
        #expect(VaultConformance.check(e, against: Self.snapshot)?.isConforming == true)
    }

    @Test func imageRequiresOnlyTitle() {
        #expect(VaultConformance.check(entry(.image), against: Self.snapshot)?.missingRequired == ["title"])
        #expect(VaultConformance.check(entry(.image, title: "Pic"), against: Self.snapshot)?.isConforming == true)
    }

    @Test func journalRequiresKindAndJournal() {
        let e = entry(.journal, kind: "overview")
        #expect(VaultConformance.check(e, against: Self.snapshot)?.missingRequired == ["journal"])
        let ok = entry(.journal, journal: "J", kind: "overview")
        #expect(VaultConformance.check(ok, against: Self.snapshot)?.isConforming == true)
    }

    @Test func noteRequiresTitleAndCreated() {
        let e = entry(.note, title: "n")
        #expect(VaultConformance.check(e, against: Self.snapshot)?.missingRequired == ["created"])
        let ok = entry(.note, title: "n", created: "2026-05-28")
        #expect(VaultConformance.check(ok, against: Self.snapshot)?.isConforming == true)
    }

    @Test func typeAbsentFromSnapshotYieldsNoOpinion() {
        // A modeled type the producing snapshot simply didn't emit → no opinion.
        let partial = SchemaSnapshot(requiredByType: ["paper": ["title"]])
        #expect(VaultConformance.check(entry(.note, title: "n"), against: partial) == nil)
    }

    @Test func otherTypeYieldsNoOpinion() {
        let e = entry(.other("topic-reading-list"), title: "x")
        #expect(VaultConformance.check(e, against: Self.snapshot) == nil)
    }

    @Test func unmodeledRequiredFieldIsNotFlagged() {
        // A future schema adds a field Marple's Entry doesn't carry. Marple can't
        // verify it → must not report a false "missing".
        let snap = SchemaSnapshot(requiredByType: ["paper": ["title", "future_field"]])
        let e = entry(.paper, title: "T")
        let result = VaultConformance.check(e, against: snap)
        #expect(result?.isConforming == true)
    }
}
