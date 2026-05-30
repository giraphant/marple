import Testing
@testable import MarpleKit

// MARK: - IndexTitlesTests
//
// TDD step 1: all tests are written BEFORE IndexTitles.swift exists.
// They cover every function in IndexTitles.swift, mirroring the plan's
// Task 3 Step 1 cases exactly.

@Suite("IndexTitles")
struct IndexTitlesTests {

    // MARK: - normaliseDoubanUrl

    @Test("normaliseDoubanUrl: all-digit string → subject URL")
    func normaliseDoubanUrlDigits() {
        #expect(normaliseDoubanUrl("12345") == "https://book.douban.com/subject/12345/")
    }

    @Test("normaliseDoubanUrl: https URL → self")
    func normaliseDoubanUrlHttps() {
        #expect(normaliseDoubanUrl("https://book.douban.com/subject/12345/") == "https://book.douban.com/subject/12345/")
    }

    @Test("normaliseDoubanUrl: http URL → self")
    func normaliseDoubanUrlHttp() {
        #expect(normaliseDoubanUrl("http://book.douban.com/subject/12345/") == "http://book.douban.com/subject/12345/")
    }

    @Test("normaliseDoubanUrl: empty string → nil")
    func normaliseDoubanUrlEmpty() {
        #expect(normaliseDoubanUrl("") == nil)
    }

    @Test("normaliseDoubanUrl: non-digit non-URL string → nil")
    func normaliseDoubanUrlNonDigit() {
        #expect(normaliseDoubanUrl("abc") == nil)
    }

    @Test("normaliseDoubanUrl: whitespace-only → nil")
    func normaliseDoubanUrlWhitespace() {
        #expect(normaliseDoubanUrl("   ") == nil)
    }

    @Test("normaliseDoubanUrl: mixed digits + letters → nil (no pure-digit id)")
    func normaliseDoubanUrlMixed() {
        // Rust: filters to only digits and checks if empty — "12abc" → id="12",
        // which is NOT empty, so it produces a URL. Verify that behaviour.
        #expect(normaliseDoubanUrl("12abc") == "https://book.douban.com/subject/12/")
    }

    // MARK: - isCJK

    @Test("isCJK: CJK Unified Ideograph 中 (U+4E2D) → true")
    func isCJKChinese() {
        #expect(isCJK(Unicode.Scalar(0x4E2D)!) == true)
    }

    @Test("isCJK: Hiragana あ (U+3042) → false")
    func isCJKHiragana() {
        #expect(isCJK(Unicode.Scalar(0x3042)!) == false)
    }

    @Test("isCJK: ASCII letter A → false")
    func isCJKAscii() {
        #expect(isCJK(Unicode.Scalar(0x41)!) == false)  // 'A'
    }

    @Test("isCJK: CJK Extension A boundary 㐀 (U+3400) → true")
    func isCJKExtALow() {
        #expect(isCJK(Unicode.Scalar(0x3400)!) == true)
    }

    @Test("isCJK: CJK Extension A boundary top (U+4DBF) → true")
    func isCJKExtAHigh() {
        #expect(isCJK(Unicode.Scalar(0x4DBF)!) == true)
    }

    @Test("isCJK: CJK Compatibility Ideographs F900 → true")
    func isCJKCompatLow() {
        #expect(isCJK(Unicode.Scalar(0xF900)!) == true)
    }

    @Test("isCJK: CJK Compatibility Ideographs FAFF → true")
    func isCJKCompatHigh() {
        #expect(isCJK(Unicode.Scalar(0xFAFF)!) == true)
    }

    @Test("isCJK: Katakana ア (U+30A2) → false")
    func isCJKKatakana() {
        #expect(isCJK(Unicode.Scalar(0x30A2)!) == false)
    }

    // MARK: - firstChineseH1

    @Test("firstChineseH1: picks H1 that contains CJK, skips English H1")
    func firstChineseH1PicksCJK() {
        let body = "# English\n# 中文标题\n"
        #expect(firstChineseH1(body) == "中文标题")
    }

    @Test("firstChineseH1: returns first CJK H1 only")
    func firstChineseH1FirstOnly() {
        let body = "# 第一\n# 第二\n"
        #expect(firstChineseH1(body) == "第一")
    }

    @Test("firstChineseH1: no CJK H1 → nil")
    func firstChineseH1NoCJK() {
        let body = "# English\n## 中文 not H1\n"
        #expect(firstChineseH1(body) == nil)
    }

    @Test("firstChineseH1: empty body → nil")
    func firstChineseH1Empty() {
        #expect(firstChineseH1("") == nil)
    }

    @Test("firstChineseH1: H2 with CJK is skipped (only H1 counts)")
    func firstChineseH1IgnoresH2() {
        let body = "## 中文\n# 中文标题\n"
        #expect(firstChineseH1(body) == "中文标题")
    }

    // MARK: - titleEn

    @Test("titleEn: title_en key → stripWiki result")
    func titleEnFromTitleEn() {
        let map: [(String, YamlValue)] = [("title_en", .string("The Dog Book"))]
        #expect(titleEn(map) == "The Dog Book")
    }

    @Test("titleEn: falls back to chapter_title_en")
    func titleEnFallbackChapter() {
        let map: [(String, YamlValue)] = [("chapter_title_en", .string("Chapter One"))]
        #expect(titleEn(map) == "Chapter One")
    }

    @Test("titleEn: title_en wins over chapter_title_en")
    func titleEnPriority() {
        let map: [(String, YamlValue)] = [
            ("title_en", .string("Main")),
            ("chapter_title_en", .string("Chapter")),
        ]
        #expect(titleEn(map) == "Main")
    }

    @Test("titleEn: empty title_en → falls back to chapter_title_en")
    func titleEnEmptyFallback() {
        let map: [(String, YamlValue)] = [
            ("title_en", .string("")),
            ("chapter_title_en", .string("Chapter")),
        ]
        #expect(titleEn(map) == "Chapter")
    }

    @Test("titleEn: strips wiki links")
    func titleEnStripWiki() {
        let map: [(String, YamlValue)] = [("title_en", .string("[[path|Display Title]]"))]
        #expect(titleEn(map) == "Display Title")
    }

    @Test("titleEn: missing → nil")
    func titleEnMissing() {
        #expect(titleEn([]) == nil)
    }

    // MARK: - titleCn

    @Test("titleCn: title_cn key → value")
    func titleCnFromTitleCn() {
        let map: [(String, YamlValue)] = [("title_cn", .string("犬的研究"))]
        #expect(titleCn(map, type: "book", title: nil, body: "") == "犬的研究")
    }

    @Test("titleCn: falls back to title_zh")
    func titleCnFallbackTitleZh() {
        let map: [(String, YamlValue)] = [("title_zh", .string("犬的研究"))]
        #expect(titleCn(map, type: "book", title: nil, body: "") == "犬的研究")
    }

    @Test("titleCn: falls back to chapter_title_cn")
    func titleCnFallbackChapterCn() {
        let map: [(String, YamlValue)] = [("chapter_title_cn", .string("第一章"))]
        #expect(titleCn(map, type: "chapter", title: nil, body: "") == "第一章")
    }

    @Test("titleCn: falls back to chapter_title_zh")
    func titleCnFallbackChapterZh() {
        let map: [(String, YamlValue)] = [("chapter_title_zh", .string("第一章"))]
        #expect(titleCn(map, type: "chapter", title: nil, body: "") == "第一章")
    }

    @Test("titleCn: book + no cn frontmatter, body has CJK H1 → fallback to H1")
    func titleCnBookOverviewH1Fallback() {
        let body = "# English Title\n# 中文\n\nSome content."
        #expect(titleCn([], type: "book", title: "English Title", body: body) == "中文")
    }

    @Test("titleCn: book + body H1 == title → nil (no self-reference)")
    func titleCnBookOverviewH1EqualTitle() {
        let body = "# 中文\n\nSome content."
        #expect(titleCn([], type: "book", title: "中文", body: body) == nil)
    }

    @Test("titleCn: non-book type → no H1 fallback")
    func titleCnNonBookOverviewNoFallback() {
        let body = "# 中文\n\nSome content."
        // paper should NOT fall back to H1
        #expect(titleCn([], type: "paper", title: nil, body: body) == nil)
    }

    @Test("titleCn: strips wiki links")
    func titleCnStripWiki() {
        let map: [(String, YamlValue)] = [("title_cn", .string("[[path|中文标题]]"))]
        #expect(titleCn(map, type: "paper", title: nil, body: "") == "中文标题")
    }

    @Test("titleCn: missing → nil")
    func titleCnMissing() {
        #expect(titleCn([], type: "paper", title: nil, body: "") == nil)
    }

    // MARK: - resolveTitle

    @Test("resolveTitle: note prefers first body heading")
    func resolveTitleNotePrefersHeading() {
        let map: [(String, YamlValue)] = [("title", .string("FM Title"))]
        #expect(resolveTitle(map, type: "note", body: "## Body Heading\ntext") == "Body Heading")
    }

    @Test("resolveTitle: note with no heading → frontmatter title")
    func resolveTitleNoteNoHeadingFmTitle() {
        let map: [(String, YamlValue)] = [("title", .string("FM Title"))]
        #expect(resolveTitle(map, type: "note", body: "just a paragraph") == "FM Title")
    }

    @Test("resolveTitle: note with no heading and no title → name")
    func resolveTitleNoteFallsBackToName() {
        let map: [(String, YamlValue)] = [("name", .string("FM Name"))]
        #expect(resolveTitle(map, type: "note", body: "just a paragraph") == "FM Name")
    }

    @Test("resolveTitle: non-note/topic ignores body heading, uses frontmatter title")
    func resolveTitleNonNoteIgnoresBody() {
        let map: [(String, YamlValue)] = [("title", .string("FM Title"))]
        #expect(resolveTitle(map, type: "paper", body: "# Body Heading\ntext") == "FM Title")
    }

    @Test("resolveTitle: non-note/topic falls back to name")
    func resolveTitleNonNoteName() {
        let map: [(String, YamlValue)] = [("name", .string("FM Name"))]
        #expect(resolveTitle(map, type: "book", body: "# Body Heading") == "FM Name")
    }

    @Test("resolveTitle: topic uses body heading like note")
    func resolveTitleTopicFromBodyHeading() {
        #expect(resolveTitle([], type: "topic", body: "# My Topic\ncontent") == "My Topic")
    }

    @Test("resolveTitle: topic body heading beats frontmatter title")
    func resolveTitleTopicHeadingOverFrontmatter() {
        let map: [(String, YamlValue)] = [("title", .string("FM Title"))]
        #expect(resolveTitle(map, type: "topic", body: "# Body Heading") == "Body Heading")
    }

    @Test("resolveTitle: topic falls back to frontmatter title when no heading")
    func resolveTitleTopicFallbackFrontmatter() {
        let map: [(String, YamlValue)] = [("title", .string("FM Title"))]
        #expect(resolveTitle(map, type: "topic", body: "just a paragraph") == "FM Title")
    }

    @Test("resolveTitle: topic falls back to name when no heading and no title")
    func resolveTitleTopicFallbackName() {
        let map: [(String, YamlValue)] = [("name", .string("FM Name"))]
        #expect(resolveTitle(map, type: "topic", body: "just a paragraph") == "FM Name")
    }

    @Test("resolveTitle: strips wiki links from frontmatter")
    func resolveTitleStripsWiki() {
        let map: [(String, YamlValue)] = [("title", .string("[[path|Real]]"))]
        #expect(resolveTitle(map, type: "paper", body: "") == "Real")
    }

    @Test("resolveTitle: nothing → nil")
    func resolveTitleNil() {
        #expect(resolveTitle([], type: "paper", body: "") == nil)
        #expect(resolveTitle([], type: "note", body: "no heading") == nil)
    }

    // MARK: - translationTitleCn + translationDoubanUrl
    // Parse a realistic localisations block via YamlFrontmatter.parseMapping

    private func makeLocalisationsMap() -> [(String, YamlValue)] {
        let yaml = """
        localisations:
          zh:
            title: 译名
            douban_url: 12345
        """
        return YamlFrontmatter.parseMapping(yaml)
    }

    @Test("translationTitleCn: localisations.zh.title → stripWiki")
    func translationTitleCnFromLocalisations() {
        let map = makeLocalisationsMap()
        #expect(translationTitleCn(map) == "译名")
    }

    @Test("translationDoubanUrl: localisations.zh.douban_url (digits) → subject URL")
    func translationDoubanUrlFromLocalisations() {
        let map = makeLocalisationsMap()
        #expect(translationDoubanUrl(map) == "https://book.douban.com/subject/12345/")
    }

    @Test("translationTitleCn: missing localisations → nil")
    func translationTitleCnMissing() {
        #expect(translationTitleCn([]) == nil)
    }

    @Test("translationDoubanUrl: no localisations, top-level douban_url → normalised")
    func translationDoubanUrlTopLevel() {
        let map: [(String, YamlValue)] = [("douban_url", .string("67890"))]
        #expect(translationDoubanUrl(map) == "https://book.douban.com/subject/67890/")
    }

    @Test("translationDoubanUrl: no localisations, top-level cndouban → normalised")
    func translationDoubanUrlCndouban() {
        let map: [(String, YamlValue)] = [("cndouban", .string("11111"))]
        #expect(translationDoubanUrl(map) == "https://book.douban.com/subject/11111/")
    }

    @Test("translationDoubanUrl: missing all → nil")
    func translationDoubanUrlMissing() {
        #expect(translationDoubanUrl([]) == nil)
    }

    // MARK: - localisation_zh: Sequence-of-Mappings variant

    @Test("translationTitleCn: zh as sequence-of-mappings takes first mapping")
    func translationTitleCnSequenceOfMappings() {
        // localisations.zh is a sequence; first item is a mapping with title
        let zhMapping: YamlValue = .sequence([
            .mapping([("title", .string("第一译名")), ("douban_url", .string("99999"))]),
        ])
        let localisations: YamlValue = .mapping([("zh", zhMapping)])
        let map: [(String, YamlValue)] = [("localisations", localisations)]
        #expect(translationTitleCn(map) == "第一译名")
        #expect(translationDoubanUrl(map) == "https://book.douban.com/subject/99999/")
    }

    // MARK: - douban_url_from_value: sequence takes first match

    @Test("translationDoubanUrl: douban_url is a sequence → picks first valid")
    func translationDoubanUrlSequencePicksFirst() {
        let map: [(String, YamlValue)] = [
            ("douban_url", .sequence([.string("22222"), .string("33333")]))
        ]
        #expect(translationDoubanUrl(map) == "https://book.douban.com/subject/22222/")
    }
}
