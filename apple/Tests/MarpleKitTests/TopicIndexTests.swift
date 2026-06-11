import Testing
@testable import MarpleKit

@Suite struct TopicIndexTests {

    private func entry(_ path: String, type: EntryType, title: String? = nil,
                       topics: [String] = []) -> Entry {
        Entry(path: path, type: type, title: title, author: [], year: nil,
              ratingScore: 0, themes: [], topics: topics, preview: "", hasPDF: false)
    }

    @Test func topicSlugTakesFirstComponentUnderVaultTopics() {
        #expect(topicSlug("vault/topics/smartphone-repair/00-overview.md") == "smartphone-repair")
        #expect(topicSlug("vault/topics/smartphone-repair/01-resources.md") == "smartphone-repair")
    }

    @Test func topicSlugRejectsPathsOutsideVaultTopics() {
        #expect(topicSlug("vault/papers/a.md") == nil)
        #expect(topicSlug("vault/topics/") == nil)
    }

    @Test func buildTopicMembershipMapsSlugToOverviewPage() {
        let overview = entry("vault/topics/repair/00-overview.md", type: .topic, title: "维修")
        let paperA = entry("vault/papers/a.md", type: .paper, topics: ["repair", "hci"])
        let paperB = entry("vault/papers/b.md", type: .paper, topics: ["repair"])

        let m = buildTopicMembership([overview, paperA, paperB])

        // topic slug → topic page entry（正向）。反向成员现入图，见下。
        #expect(m.topicEntryBySlug["repair"]?.path == "vault/topics/repair/00-overview.md")
        #expect(m.topicEntryBySlug["hci"] == nil)  // 无 hci topic 页
    }

    // 反向（topic 页 ← 成员）现由 RelationGraph 的 inTopic 边产出（QUA-218 规则①收口）。
    @Test func topicMembersViaInTopicEdges() {
        let overview = entry("vault/topics/repair/00-overview.md", type: .topic, title: "维修")
        let paperA = entry("vault/papers/a.md", type: .paper, topics: ["repair", "hci"])
        let paperB = entry("vault/papers/b.md", type: .paper, topics: ["repair"])
        let g = RelationGraph.build([overview, paperA, paperB])
        #expect(g.sources(of: overview.path, kind: .inTopic).map(\.path)
                == ["vault/papers/a.md", "vault/papers/b.md"])
    }

    @Test func topicEntryBySlugPrefersFirstFileByPath() {
        // Two files share the same topic slug; the earlier path (00-overview)
        // wins so resolution lands on the overview, not the resources index.
        let overview = entry("vault/topics/repair/00-overview.md", type: .topic, title: "维修概览")
        let resources = entry("vault/topics/repair/01-resources.md", type: .topic, title: "维修资源")

        let m = buildTopicMembership([resources, overview])
        #expect(m.topicEntryBySlug["repair"]?.path == "vault/topics/repair/00-overview.md")
    }

    @Test func topicDisplayTitleResolvesSlugToCanonicalTopicTitleOrNil() {
        let overview = entry("vault/topics/repair/00-overview.md", type: .topic, title: "维修")
        let resources = entry("vault/topics/repair/01-resources.md", type: .topic, title: "维修资源")
        let entries = [resources, overview]
        #expect(topicDisplayTitle(forSlug: "repair", in: entries) == "维修")
        #expect(topicDisplayTitle(forSlug: "missing", in: entries) == nil)
    }
}
