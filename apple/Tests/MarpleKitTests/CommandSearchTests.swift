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

    @Test func nonFastModesUseInlineScoreFloor() {
        #expect(SearchMode.fast.paletteInlineScoreFloorRatio == nil)
        #expect(SearchMode.balanced.paletteInlineScoreFloorRatio == 0.60)
        #expect(SearchMode.deep.paletteInlineScoreFloorRatio == 0.60)
    }

    let order = EntryType.modeled

    @Test func groupsByTypeInOrder() {
        let rows = [e("p1", .paper), e("b1", .book), e("p2", .paper)]
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5)
        #expect(sections.map(\.type) == [.paper, .book])
        #expect(sections[0].total == 2)
        #expect(sections[1].total == 1)
    }

    @Test func perTypeLimitWithFullTotal() {
        let rows = (1...8).map { e("p\($0)", .paper, score: Double($0)) }
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5)
        #expect(sections.count == 1)
        #expect(sections[0].total == 8)
        #expect(sections[0].top.count == 5)
    }

    @Test func inlineScoreFloorCollapsesLowRowsAgainstGlobalBest() {
        let rows = [
            e("paper-strong", .paper, score: 100),
            e("paper-low", .paper, score: 20),
            e("book-strong", .book, score: 61),
            e("book-low", .book, score: 59),
            e("summary-low", .chapter, score: 30),
            e("note-low", .note, score: 10),
        ]
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5,
                                       minimumInlineScoreRatio: 0.60)
        #expect(sections.map(\.type) == [.paper, .book, .chapter, .note])
        #expect(sections[0].total == 2)
        #expect(sections[0].top.map(\.path) == ["paper-strong"])
        #expect(sections[1].total == 2)
        #expect(sections[1].top.map(\.path) == ["book-strong"])
    }

    @Test func inlineScoreFloorKeepsLowSectionsCollapsed() {
        let rows = [
            e("paper-strong", .paper, score: 100),
            e("book-low-1", .book, score: 50),
            e("book-low-2", .book, score: 49),
            e("book-low-3", .book, score: 48),
            e("book-low-4", .book, score: 47),
            e("book-low-5", .book, score: 46),
        ]
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5,
                                       minimumInlineScoreRatio: 0.60)
        #expect(sections.map(\.type) == [.paper, .book])
        #expect(sections[1].total == 5)
        #expect(sections[1].top.isEmpty)
    }

    @Test func inlineScoreFloorDoesNotCollapseSmallResultSets() {
        let rows = [
            e("paper-strong", .paper, score: 100),
            e("book-low", .book, score: 40),
        ]
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5,
                                       minimumInlineScoreRatio: 0.60)
        #expect(sections.flatMap(\.top).map(\.path) == ["paper-strong", "book-low"])
    }

    @Test func withinBucketSortedByScoreDesc() {
        let rows = [e("low", .paper, score: 1), e("high", .paper, score: 9),
                    e("mid", .paper, score: 5)]
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5)
        #expect(sections[0].top.map(\.path) == ["high", "mid", "low"])
    }

    @Test func promotePullsTypeToFront() {
        let rows = [e("p1", .paper), e("b1", .book)]
        let sections = paletteSections(rows, order: order, promote: .book, perType: 5)
        #expect(sections.first?.type == .book)
    }

    @Test func dropsEmptyAndUnorderedTypes() {
        // .other is not in EntryType.modeled → its bucket is dropped.
        let rows = [e("p1", .paper), e("x1", .other("topic-reading-list"))]
        let sections = paletteSections(rows, order: order, promote: nil, perType: 5)
        #expect(sections.map(\.type) == [.paper])
    }

    @Test func emptyInputYieldsNoSections() {
        #expect(paletteSections([], order: order, promote: nil, perType: 5).isEmpty)
    }
}
