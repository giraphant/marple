import Testing
@testable import MarpleKit

@Suite("IndexFields")
struct IndexFieldsTests {

    // MARK: - canonicalType

    @Test("canonicalType: paper → paper-analysis")
    func canonicalTypePaper() {
        #expect(canonicalType("paper") == "paper-analysis")
    }

    @Test("canonicalType: paper-summary → paper-analysis")
    func canonicalTypePaperSummary() {
        #expect(canonicalType("paper-summary") == "paper-analysis")
    }

    @Test("canonicalType: article-analysis → paper-analysis")
    func canonicalTypeArticleAnalysis() {
        #expect(canonicalType("article-analysis") == "paper-analysis")
    }

    @Test("canonicalType: journal-article → paper-analysis")
    func canonicalTypeJournalArticle() {
        #expect(canonicalType("journal-article") == "paper-analysis")
    }

    @Test("canonicalType: journal-article-analysis → paper-analysis")
    func canonicalTypeJournalArticleAnalysis() {
        #expect(canonicalType("journal-article-analysis") == "paper-analysis")
    }

    @Test("canonicalType: author → author-profile")
    func canonicalTypeAuthor() {
        #expect(canonicalType("author") == "author-profile")
    }

    @Test("canonicalType: book → book-overview")
    func canonicalTypeBook() {
        #expect(canonicalType("book") == "book-overview")
    }

    @Test("canonicalType: book-analysis → book-overview")
    func canonicalTypeBookAnalysis() {
        #expect(canonicalType("book-analysis") == "book-overview")
    }

    @Test("canonicalType: monograph → book-overview")
    func canonicalTypeMonograph() {
        #expect(canonicalType("monograph") == "book-overview")
    }

    @Test("canonicalType: monograph-analysis → book-overview")
    func canonicalTypeMonographAnalysis() {
        #expect(canonicalType("monograph-analysis") == "book-overview")
    }

    @Test("canonicalType: overview → book-overview")
    func canonicalTypeOverview() {
        #expect(canonicalType("overview") == "book-overview")
    }

    @Test("canonicalType: chapter → chapter-summary")
    func canonicalTypeChapter() {
        #expect(canonicalType("chapter") == "chapter-summary")
    }

    @Test("canonicalType: book-chapter → chapter-summary")
    func canonicalTypeBookChapter() {
        #expect(canonicalType("book-chapter") == "chapter-summary")
    }

    @Test("canonicalType: book_chapter → chapter-summary")
    func canonicalTypeBookChapterUnderscore() {
        #expect(canonicalType("book_chapter") == "chapter-summary")
    }

    @Test("canonicalType: chapter-analysis → chapter-summary")
    func canonicalTypeChapterAnalysis() {
        #expect(canonicalType("chapter-analysis") == "chapter-summary")
    }

    @Test("canonicalType: journal-synthesis → topic-synthesis")
    func canonicalTypeJournalSynthesis() {
        #expect(canonicalType("journal-synthesis") == "topic-synthesis")
    }

    @Test("canonicalType: snowball-synthesis → topic-synthesis")
    func canonicalTypeSnowballSynthesis() {
        #expect(canonicalType("snowball-synthesis") == "topic-synthesis")
    }

    @Test("canonicalType: citation-snowball-synthesis → topic-synthesis")
    func canonicalTypeCitationSnowball() {
        #expect(canonicalType("citation-snowball-synthesis") == "topic-synthesis")
    }

    @Test("canonicalType: reading-list → topic-synthesis")
    func canonicalTypeReadingList() {
        #expect(canonicalType("reading-list") == "topic-synthesis")
    }

    @Test("canonicalType: research-note → topic-synthesis")
    func canonicalTypeResearchNote() {
        #expect(canonicalType("research-note") == "topic-synthesis")
    }

    @Test("canonicalType: concept-note → topic-synthesis")
    func canonicalTypeConceptNote() {
        #expect(canonicalType("concept-note") == "topic-synthesis")
    }

    @Test("canonicalType: empty string → nil")
    func canonicalTypeEmpty() {
        #expect(canonicalType("") == nil)
    }

    @Test("canonicalType: 'A' → nil")
    func canonicalTypeA() {
        #expect(canonicalType("A") == nil)
    }

    @Test("canonicalType: unknown non-empty → passthrough")
    func canonicalTypeUnknownPassthrough() {
        #expect(canonicalType("note") == "note")
        #expect(canonicalType("weird") == "weird")
    }

    // MARK: - ratingScore

    @Test("ratingScore: ★★★ → 3")
    func ratingScoreThreeStars() {
        #expect(ratingScore(.string("★★★")) == 3.0)
    }

    @Test("ratingScore: ★★ → 2")
    func ratingScoreTwoStars() {
        #expect(ratingScore(.string("★★")) == 2.0)
    }

    @Test("ratingScore: int 4 → 4.0")
    func ratingScoreInt() {
        #expect(ratingScore(.int(4)) == 4.0)
    }

    @Test("ratingScore: double 4.5 → 4.5")
    func ratingScoreDouble() {
        #expect(ratingScore(.double(4.5)) == 4.5)
    }

    @Test("ratingScore: string '4.5' (no stars) → parse as 4.5")
    func ratingScoreStringParsed() {
        #expect(ratingScore(.string("4.5")) == 4.5)
    }

    @Test("ratingScore: non-parseable string → 0")
    func ratingScoreStringFoo() {
        #expect(ratingScore(.string("foo")) == 0.0)
    }

    @Test("ratingScore: nil → 0")
    func ratingScoreNil() {
        #expect(ratingScore(nil) == 0.0)
    }

    @Test("ratingScore: .null → 0")
    func ratingScoreYamlNull() {
        #expect(ratingScore(.null) == 0.0)
    }

    // MARK: - stripWiki

    @Test("stripWiki: pipe form → display text")
    func stripWikiPipe() {
        #expect(stripWiki("[[vault/x.md|Display]]") == "Display")
    }

    @Test("stripWiki: no pipe → target text")
    func stripWikiNoSeparator() {
        #expect(stripWiki("[[Target]]") == "Target")
    }

    @Test("stripWiki: plain string → unchanged")
    func stripWikiPlain() {
        #expect(stripWiki("plain") == "plain")
    }

    @Test("stripWiki: multiple links")
    func stripWikiMultiple() {
        #expect(stripWiki("See [[foo|Foo]] and [[Bar]]") == "See Foo and Bar")
    }

    @Test("stripWiki: display trimmed")
    func stripWikiDisplayTrimmed() {
        // The Rust `.trim()` on display means surrounding whitespace is stripped.
        #expect(stripWiki("[[path| Solo ]]") == "Solo")
    }

    // MARK: - parseAuthors  (replaced flattenAuthor in QUA-109)

    @Test("parseAuthors: sequence of strings → list")
    func parseAuthorsSequence() {
        #expect(parseAuthors(.sequence([.string("A"), .string("B")])) == ["A", "B"])
    }

    @Test("parseAuthors: scalar with wiki link → 1-element list")
    func parseAuthorsScalarWiki() {
        #expect(parseAuthors(.string("[[x|Solo]]")) == ["Solo"])
    }

    @Test("parseAuthors: scalar bare name → 1-element list")
    func parseAuthorsScalarBare() {
        #expect(parseAuthors(.string("Solo Author")) == ["Solo Author"])
    }

    @Test("parseAuthors: legacy comma scalar → split via splitAuthors")
    func parseAuthorsScalarLegacyComma() {
        #expect(parseAuthors(.string("A, B & C")) == ["A", "B", "C"])
    }

    @Test("parseAuthors: nil → empty list")
    func parseAuthorsNilEmpty() {
        #expect(parseAuthors(nil) == [])
    }

    @Test("parseAuthors: null → empty list")
    func parseAuthorsNull() {
        #expect(parseAuthors(.null) == [])
    }

    @Test("parseAuthors: sequence filters empty after stripWiki")
    func parseAuthorsSequenceFiltersEmpty() {
        let result = parseAuthors(.sequence([.string("A"), .string(""), .string("B")]))
        #expect(result == ["A", "B"])
    }

    // MARK: - themeArray

    @Test("themeArray: sequence → [String]")
    func themeArraySequence() {
        #expect(themeArray(.sequence([.string("ai"), .string("ethics")])) == ["ai", "ethics"])
    }

    @Test("themeArray: scalar → nil")
    func themeArrayScalar() {
        #expect(themeArray(.string("ai")) == nil)
    }

    @Test("themeArray: null → nil")
    func themeArrayNull() {
        #expect(themeArray(.null) == nil)
    }

    // MARK: - textValue

    @Test("textValue: bool true → 'true'")
    func textValueBoolTrue() {
        #expect(textValue(.bool(true)) == "true")
    }

    @Test("textValue: bool false → 'false'")
    func textValueBoolFalse() {
        #expect(textValue(.bool(false)) == "false")
    }

    @Test("textValue: int → stringified")
    func textValueInt() {
        #expect(textValue(.int(3)) == "3")
    }

    @Test("textValue: double → stringified")
    func textValueDouble() {
        #expect(textValue(.double(3.5)) == "3.5")
    }

    @Test("textValue: null → nil")
    func textValueNull() {
        #expect(textValue(.null) == nil)
    }

    @Test("textValue: nil → nil")
    func textValueNilInput() {
        #expect(textValue(nil) == nil)
    }

    @Test("textValue: sequence → compact JSON")
    func textValueSequence() {
        #expect(textValue(.sequence([.int(1)])) == "[1]")
    }

    @Test("textValue: string → self")
    func textValueString() {
        #expect(textValue(.string("hello")) == "hello")
    }

    // MARK: - fieldJSONCell

    @Test("fieldJSONCell: int → bare number string")
    func fieldJSONInt() {
        #expect(fieldJSONCell(.int(2019)) == "2019")
    }

    @Test("fieldJSONCell: string → quoted JSON string")
    func fieldJSONString() {
        #expect(fieldJSONCell(.string("2019")) == "\"2019\"")
    }

    @Test("fieldJSONCell: sequence of ints → compact JSON array")
    func fieldJSONSequenceInts() {
        #expect(fieldJSONCell(.sequence([.int(2010), .int(2015)])) == "[2010,2015]")
    }

    @Test("fieldJSONCell: null → nil")
    func fieldJSONNull() {
        #expect(fieldJSONCell(.null) == nil)
    }

    @Test("fieldJSONCell: bool true → 'true'")
    func fieldJSONBoolTrue() {
        #expect(fieldJSONCell(.bool(true)) == "true")
    }

    @Test("fieldJSONCell: sequence of strings")
    func fieldJSONSequenceStrings() {
        #expect(fieldJSONCell(.sequence([.string("ai"), .string("ethics")])) == "[\"ai\",\"ethics\"]")
    }

    // MARK: - truthyJSONCell

    @Test("truthyJSONCell: bool false → nil")
    func truthyJSONFalse() {
        #expect(truthyJSONCell(.bool(false)) == nil)
    }

    @Test("truthyJSONCell: int 0 → nil")
    func truthyJSONZeroInt() {
        #expect(truthyJSONCell(.int(0)) == nil)
    }

    @Test("truthyJSONCell: double 0.0 → nil")
    func truthyJSONZeroDouble() {
        #expect(truthyJSONCell(.double(0.0)) == nil)
    }

    @Test("truthyJSONCell: empty string → nil")
    func truthyJSONEmptyString() {
        #expect(truthyJSONCell(.string("")) == nil)
    }

    @Test("truthyJSONCell: null → nil")
    func truthyJSONNull() {
        #expect(truthyJSONCell(.null) == nil)
    }

    @Test("truthyJSONCell: star string → JSON string")
    func truthyJSONStars() {
        #expect(truthyJSONCell(.string("★★")) == "\"★★\"")
    }

    @Test("truthyJSONCell: int 1 → '1'")
    func truthyJSONNonZeroInt() {
        #expect(truthyJSONCell(.int(1)) == "1")
    }

    // MARK: - intValue

    @Test("intValue: string '12' → 12")
    func intValueStringParse() {
        #expect(intValue(.string("12")) == 12)
    }

    @Test("intValue: double 3.9 → 3 (truncated)")
    func intValueDoubleTruncated() {
        #expect(intValue(.double(3.9)) == 3)
    }

    @Test("intValue: string 'x' → nil")
    func intValueStringNonparse() {
        #expect(intValue(.string("x")) == nil)
    }

    @Test("intValue: int 42 → 42")
    func intValueInt() {
        #expect(intValue(.int(42)) == 42)
    }

    @Test("intValue: null → nil")
    func intValueNull() {
        #expect(intValue(.null) == nil)
    }

    @Test("intValue: nil → nil")
    func intValueNilInput() {
        #expect(intValue(nil) == nil)
    }

    // MARK: - field

    @Test("field: first case-sensitive match")
    func fieldLookup() {
        let map: [(String, YamlValue)] = [("type", .string("paper-analysis")), ("title", .string("Hello"))]
        #expect(field(map, "type") == .string("paper-analysis"))
        #expect(field(map, "title") == .string("Hello"))
        #expect(field(map, "Type") == nil)
        #expect(field(map, "missing") == nil)
    }

    // MARK: - truthyText

    @Test("truthyText: non-empty value")
    func truthyTextNonEmpty() {
        let map: [(String, YamlValue)] = [("type", .string("paper-analysis"))]
        #expect(truthyText(map, "type") == "paper-analysis")
    }

    @Test("truthyText: empty string → nil")
    func truthyTextEmpty() {
        let map: [(String, YamlValue)] = [("type", .string(""))]
        #expect(truthyText(map, "type") == nil)
    }

    @Test("truthyText: missing key → nil")
    func truthyTextMissing() {
        let map: [(String, YamlValue)] = []
        #expect(truthyText(map, "type") == nil)
    }
}
