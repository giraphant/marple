import Testing
@testable import MarpleKit

@Suite struct FrontmatterPatchScalarTests {
    let file = "---\ntype: paper\ntitle: 风险\nyear: 2019\n---\n\nbody line\n"

    @Test func updatesExistingScalarInPlace() {
        let out = FrontmatterPatch.setScalar(file, key: "year", value: "2020", numeric: true)
        #expect(out.contains("year: 2020"))
        #expect(!out.contains("year: 2019"))
        #expect(out.hasSuffix("body line\n"))
    }
    @Test func numericFieldStaysBare() {
        let out = FrontmatterPatch.setScalar(file, key: "year", value: "2020", numeric: true)
        #expect(!out.contains(#"year: "2020""#))
    }
    @Test func insertsMissingScalarBeforeClosingFence() {
        let out = FrontmatterPatch.setScalar(file, key: "rating", value: "★★★")
        #expect(out.contains("rating: ★★★"))
        let bodyStart = out.range(of: "\n---\n")!
        #expect(out.range(of: "rating: ★★★")!.upperBound <= bodyStart.lowerBound)
    }
    @Test func clearRemovesLine() {
        let out = FrontmatterPatch.setScalar(file, key: "year", value: nil)
        #expect(!out.contains("year:"))
        #expect(out.contains("title: 风险"))
        #expect(out.hasSuffix("body line\n"))
    }
    @Test func quotesValueWithColon() {
        let out = FrontmatterPatch.setScalar(file, key: "source", value: "a: b")
        #expect(out.contains(#"source: "a: b""#))
    }
    @Test func plainValueNoQuotesForCJK() {
        let out = FrontmatterPatch.setScalar(file, key: "topic", value: "技术物")
        #expect(out.contains("topic: 技术物"))
    }
    @Test func quotesNumericText() {
        let out = FrontmatterPatch.setScalar(file, key: "source", value: "2020")
        #expect(out.contains(#"source: "2020""#))
    }
    @Test func idempotentOnSameValue() {
        #expect(FrontmatterPatch.setScalar(file, key: "year", value: "2019", numeric: true) == file)
    }
    @Test func clearMissingKeyIsNoOp() {
        #expect(FrontmatterPatch.setScalar(file, key: "rating", value: nil) == file)
    }
    @Test func noFrontmatterReturnsUnchanged() {
        let raw = "no fm here\n"
        #expect(FrontmatterPatch.setScalar(raw, key: "year", value: "2020") == raw)
    }
}

@Suite struct FrontmatterPatchThemesTests {
    @Test func rewritesFlowThemes() {
        let f = "---\ntype: paper\nthemes: [a, b]\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["a", "b", "c"])
        #expect(out.contains("themes: [a, b, c]"))
        #expect(!out.contains("themes: [a, b]\n"))
        #expect(out.hasSuffix("body\n"))
    }
    @Test func emptyThemesEmitsBrackets() {
        let f = "---\nthemes: [a]\n---\nbody\n"
        #expect(FrontmatterPatch.setThemes(f, []).contains("themes: []"))
    }
    @Test func fixesMalformedThemes() {
        let f = "---\ntype: note\nthemes: []()\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["x"])
        #expect(out.contains("themes: [x]"))
        #expect(!out.contains("[]()"))
    }
    @Test func insertsThemesWhenAbsent() {
        let f = "---\ntype: paper\n---\nbody\n"
        #expect(FrontmatterPatch.setThemes(f, ["x"]).contains("themes: [x]"))
    }
    @Test func quotesThemeWithComma() {
        let f = "---\nthemes: []\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["a, b"])
        #expect(out.contains(#"themes: ["a, b"]"#))
    }
    @Test func cjkThemesStayPlain() {
        let f = "---\nthemes: []\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["视觉社会学", "技能知识"])
        #expect(out.contains("themes: [视觉社会学, 技能知识]"))
    }
}
