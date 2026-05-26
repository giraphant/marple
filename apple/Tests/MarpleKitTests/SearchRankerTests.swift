import Testing
@testable import MarpleKit

@Suite struct SearchRankerTests {
    func e(_ path: String, type: EntryType = .paperAnalysis, title: String? = nil,
           author: String? = nil, themes: [String] = [], topic: String? = nil,
           source: String? = nil, book: String? = nil, year: String? = nil,
           preview: String = "", doi: String? = nil, rating: Double = 0) -> Entry {
        Entry(path: path, type: type, title: title, author: author, year: year,
              ratingScore: rating, themes: themes, preview: preview, hasPDF: false,
              source: source, book: book, topic: topic, doi: doi)
    }

    func paths(_ entries: [Entry], _ query: String) -> [String] {
        searchEntries(entries, query).map { $0.entry.path }
    }

    @Test func emptyQueryReturnsNothing() {
        let list = [e("a", title: "Quantum")]
        #expect(searchEntries(list, "").isEmpty)
        #expect(searchEntries(list, "   ").isEmpty)
    }

    @Test func titleBeatsPreview() {
        let a = e("a", title: "Quantum Mechanics")
        let b = e("b", preview: "a note on quantum effects")
        #expect(paths([b, a], "quantum") == ["a", "b"])
    }

    @Test func everyTokenMustMatch() {
        let a = e("a", title: "Quantum Mechanics")
        // "banana" matches no field → the whole entry scores 0 and is dropped.
        #expect(searchEntries([a], "quantum banana").isEmpty)
    }

    @Test func asciiFuzzyFallback() {
        let a = e("a", title: "Learning Theory")
        let b = e("b", title: "Cooking Recipes")
        // "lerning" is a 1-edit typo of "learning" (not a substring), so only the
        // fuzzy path can match it.
        #expect(paths([a, b], "lerning") == ["a"])
    }

    @Test func phraseBonusRanksContiguousHigher() {
        let a = e("a", title: "machine learning models")
        let b = e("b", title: "learning a machine")
        let result = paths([b, a], "machine learning")
        #expect(result == ["a", "b"])   // a has the contiguous phrase, b doesn't
    }

    @Test func chineseSubstringMatch() {
        let a = e("a", title: "量表与测量方法")
        let b = e("b", title: "完全无关的标题")
        #expect(paths([a, b], "量表") == ["a"])
    }

    @Test func shortNumericTokenSearchesTitleAndYearOnly() {
        let a = e("a", title: "Census 2020", year: "2020")
        let c = e("c", title: "Unrelated", preview: "mentions 2020 in passing")
        let found = Set(paths([a, c], "2020"))
        #expect(found.contains("a"))
        #expect(!found.contains("c"))   // preview excluded for short numeric tokens
    }

    @Test func doiIdentifierMatch() {
        let a = e("a", title: "Some Paper", doi: "10.1000/xyz123")
        let b = e("b", title: "Other Paper")
        #expect(paths([a, b], "10.1000/xyz123") == ["a"])
    }

    @Test func fuzzy5ByteAllTrigramsDifferStillMatches() {
        // QUA-96 trigram filter edge case (caught in Codex audit). A 5-byte
        // ASCII token has 3 trigrams, and a 1-edit fuzzy match can wipe ALL
        // three trigrams ("abxde" vs "abcde" → abx/bxd/xde share nothing with
        // abc/bcd/cde). The trigram pre-filter must not drop these.
        let a = e("a", title: "abcde paper")
        #expect(paths([a], "abxde") == ["a"])
    }

    @Test func fuzzy8ByteAllTrigramsDifferStillMatches() {
        // Same edge case at the 8-byte / 2-edit boundary: "abxdeygh" vs
        // "abcdefgh" with edits at positions 2 and 5 — every one of the
        // token's 6 trigrams differs from every one of the word's 6 trigrams,
        // but Levenshtein distance is 2 (within budget).
        let a = e("a", title: "abcdefgh study")
        #expect(paths([a], "abxdeygh") == ["a"])
    }

    @Test func nonFuzzyTokenWithNoTrigramHitReturnsEmptyFast() {
        // Performance regression guard: a non-fuzzy token whose trigrams are
        // absent from every doc must bail out without full-scanning the corpus.
        // CJK is non-fuzzy (canFuzzyBytes requires all-ASCII-alnum).
        let a = e("a", title: "完全无关")
        #expect(searchEntries([a], "钦差大臣").isEmpty)
    }

    @Test func resultsSortedByScoreDescending() {
        let strong = e("strong", title: "alpha beta", themes: ["alpha"])
        let weak = e("weak", preview: "alpha appears once here")
        let result = searchEntries([weak, strong], "alpha")
        #expect(result.map { $0.entry.path } == ["strong", "weak"])
        #expect(result[0].score > result[1].score)
    }
}
