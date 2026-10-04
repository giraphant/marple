import Foundation
import Testing
@testable import MarpleKit

struct ArchiveFieldGroupTests {
    @Test func scalarAndMultipleValuesGroupWithStableMissingBucket() {
        let fields = ["a": ["collection": ["Work"], "topics": ["one", "two"]],
                      "b": ["collection": ["Work"], "topics": ["two"]],
                      "c": ["source": ["Publisher"]]]
        let single = ArchiveFieldGroup.groups(paths: ["a", "b", "c"], fields: fields, by: "collection")
        #expect(single.count == 2)
        #expect(single[0].members == ["a", "b"])
        #expect(single[1].value == nil && single[1].members == ["c"])
        let topics = ArchiveFieldGroup.groups(paths: ["a", "b", "a"], fields: fields, by: "topics")
        #expect(topics.map(\.members) == [["a"], ["a", "b"]])
        #expect(topics[0].entryPath != single[0].entryPath)
        #expect(ArchiveFieldGroup.values(.sequence([.string(" a "), .string("a"), .null, .bool(false), .int(0)])) == ["a", "false", "0"])
        #expect(ArchiveFieldGroup.values(.mapping([("nested", .string("value"))])).isEmpty)
    }
    @Test func groupingPreferenceDistinguishesUngroupedFromLegacyState() throws {
        var state = PersistedState(browsePane: .type(.archive), isBrowsing: true, tabs: [], activeIndex: 0,
            sortClauses: [], filterClauses: [], filterMatch: .all, browseMode: "grid")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        #expect(try decoder.decode(PersistedState.self, from: encoder.encode(state)).archiveGrouping == nil)
        state.archiveGrouping = ""
        #expect(try decoder.decode(PersistedState.self, from: encoder.encode(state)).archiveGrouping == "")
        state.archiveGrouping = "topics"
        #expect(try decoder.decode(PersistedState.self, from: encoder.encode(state)).archiveGrouping == "topics")
    }

}
