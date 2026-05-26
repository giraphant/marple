import Testing
@testable import MarpleKit

@Suite struct CommandSearchTests {
    func e(_ path: String, _ type: EntryType, score: Double = 1) -> (entry: Entry, score: Double) {
        (Entry(path: path, type: type, title: path, author: [], year: nil,
               ratingScore: 0, themes: [], preview: "", hasPDF: false), score)
    }

    @Test func modeCycleWraps() {
        #expect(SearchMode.fast.next() == .balanced)
        #expect(SearchMode.balanced.next() == .deep)
        #expect(SearchMode.deep.next() == .fast)
    }

    @Test func modeOrder() {
        #expect(SearchMode.allCases == [.fast, .balanced, .deep])
    }

    @Test func sourceBadgeMapping() {
        #expect(searchSourceBadge("hybrid") == "混合")
        #expect(searchSourceBadge("vec") == "向量")
        #expect(searchSourceBadge("hybrid (lex-fallback)") == "混合")  // leading token
        #expect(searchSourceBadge("phrase") == nil)
        #expect(searchSourceBadge(nil) == nil)
    }

    let order = EntryType.modeled

    @Test func groupsByTypeInOrder() {
        let rows = [e("p1", .paperAnalysis), e("b1", .bookOverview), e("p2", .paperAnalysis)]
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5)
        #expect(sections.map(\.type) == [.paperAnalysis, .bookOverview])
        #expect(sections[0].total == 2)
        #expect(sections[1].total == 1)
    }

    @Test func perTypeLimitWithFullTotal() {
        let rows = (1...8).map { e("p\($0)", .paperAnalysis, score: Double($0)) }
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5)
        #expect(sections.count == 1)
        #expect(sections[0].total == 8)
        #expect(sections[0].top.count == 5)
    }

    @Test func withinBucketSortedByScoreDesc() {
        let rows = [e("low", .paperAnalysis, score: 1), e("high", .paperAnalysis, score: 9),
                    e("mid", .paperAnalysis, score: 5)]
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5)
        #expect(sections[0].top.map(\.path) == ["high", "mid", "low"])
    }

    @Test func promotePullsTypeToFront() {
        let rows = [e("p1", .paperAnalysis), e("b1", .bookOverview)]
        let sections = paletteSections(rows, order: order, promote: .bookOverview, perType: 5)
        #expect(sections.first?.type == .bookOverview)
    }

    @Test func dropsEmptyAndUnorderedTypes() {
        // .other is not in EntryType.modeled → its bucket is dropped.
        let rows = [e("p1", .paperAnalysis), e("x1", .other("topic-reading-list"))]
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5)
        #expect(sections.map(\.type) == [.paperAnalysis])
    }

    @Test func emptyInputYieldsNoSections() {
        #expect(paletteSections([], order: order, promote: nil, perType: 5).isEmpty)
    }
}
