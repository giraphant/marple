import Testing
@testable import MarpleKit

@Suite("YamlFrontmatter")
struct YamlFrontmatterTests {

    // MARK: - Well-formed mapping

    @Test("Well-formed mapping: scalars + nested sequence")
    func wellFormedMapping() {
        let raw = """
        type: paper
        title: Hello
        year: 2019
        themes:
          - ai
          - ethics
        """
        let result = YamlFrontmatter.parseMapping(raw)
        let dict = Dictionary(uniqueKeysWithValues: result)
        #expect(dict["type"] == .string("paper"))
        #expect(dict["title"] == .string("Hello"))
        #expect(dict["year"] == .int(2019))
        #expect(dict["themes"] == .sequence([.string("ai"), .string("ethics")]))
        // Ordering preserved: type first, then title, year, themes
        #expect(result.map(\.0) == ["type", "title", "year", "themes"])
    }

    // MARK: - Lenient rescue: unquoted inner colon

    @Test("Lenient rescue: unquoted inner colon in value — full YAML fails, lenient rescues both keys")
    func lenientRescueInnerColon() {
        // "book: Understanding Dogs: A Study\ntype: book"
        // serde_yaml / Yams will reject this because of the unquoted inner ':'
        // The lenient fallback must rescue BOTH keys.
        let raw = "book: Understanding Dogs: A Study\ntype: book"
        let result = YamlFrontmatter.parseMapping(raw)
        let dict = Dictionary(uniqueKeysWithValues: result)
        #expect(dict["book"] == .string("Understanding Dogs: A Study"))
        #expect(dict["type"] == .string("book"))
        #expect(result.count == 2)
    }

    // MARK: - Quoted value with inner colon

    @Test("Quoted value with inner colon — full YAML handles it")
    func quotedValueWithColon() {
        let raw = #"title: "Hello: World""#
        let result = YamlFrontmatter.parseMapping(raw)
        let dict = Dictionary(uniqueKeysWithValues: result)
        #expect(dict["title"] == .string("Hello: World"))
    }

    // MARK: - CJK full-width colon is NOT a separator

    @Test("CJK full-width colon '：' is not a separator — line is ignored")
    func cjkFullWidthColonNotSeparator() {
        // "作者：张三" has a full-width colon (U+FF1A), not ASCII ':'
        // It should produce NO key in the mapping.
        let raw = "作者：张三"
        let result = YamlFrontmatter.parseMapping(raw)
        // The line has no ASCII colon so the lenient parser ignores it.
        // Neither path should produce a "作者" key.
        let keys = result.map(\.0)
        #expect(!keys.contains("作者"))
        #expect(!keys.contains("作者：张三"))
    }

    // MARK: - Comment and blank lines skipped

    @Test("Comment and blank lines are skipped")
    func commentsAndBlanksSkipped() {
        let raw = "# c\n\ntype: note"
        let result = YamlFrontmatter.parseMapping(raw)
        let dict = Dictionary(uniqueKeysWithValues: result)
        #expect(result.count == 1)
        #expect(dict["type"] == .string("note"))
    }

    // MARK: - Flow sequence

    @Test("Flow sequence: themes: [ai, ethics]")
    func flowSequence() {
        let raw = "themes: [ai, ethics]"
        let result = YamlFrontmatter.parseMapping(raw)
        let dict = Dictionary(uniqueKeysWithValues: result)
        #expect(dict["themes"] == .sequence([.string("ai"), .string("ethics")]))
    }

    // MARK: - Empty / no-mapping input

    @Test("Empty string returns empty mapping")
    func emptyInput() {
        let result = YamlFrontmatter.parseMapping("")
        #expect(result.isEmpty)
    }

    @Test("Plain text (no keys) returns empty mapping")
    func plainTextInput() {
        let result = YamlFrontmatter.parseMapping("just text")
        #expect(result.isEmpty)
    }
}
