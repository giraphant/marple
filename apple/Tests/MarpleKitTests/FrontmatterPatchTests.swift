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
    // setThemes is now a block-list emitter per SPEC §5.2 (Ulysses-safe).
    // Empty values remove the field entirely; non-empty values use block form.

    @Test func rewritesFlowToBlock() {
        let f = "---\ntype: paper\nthemes: [a, b]\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["a", "b", "c"])
        #expect(out.contains("themes:\n  - a\n  - b\n  - c"))
        #expect(!out.contains("themes: [a, b]"))
        #expect(out.hasSuffix("body\n"))
    }

    @Test func emptyThemesRemovesField() {
        let f = "---\ntype: paper\nthemes: [a]\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, [])
        #expect(!out.contains("themes:"))
        #expect(out.contains("type: paper"))
        #expect(out.hasSuffix("body\n"))
    }

    @Test func emptyOnBlockListAlsoRemovesContinuation() {
        let f = "---\ntype: paper\nthemes:\n  - a\n  - b\nyear: 2020\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, [])
        #expect(!out.contains("themes:"))
        #expect(!out.contains("- a"))
        #expect(!out.contains("- b"))
        #expect(out.contains("year: 2020"))
    }

    @Test func insertsThemesWhenAbsent() {
        let f = "---\ntype: paper\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["x"])
        #expect(out.contains("themes:\n  - x"))
    }

    @Test func quotesThemeWithComma() {
        let f = "---\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["a, b"])
        #expect(out.contains(#"  - "a, b""#))
    }

    @Test func cjkThemesStayPlain() {
        let f = "---\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["视觉社会学", "技能知识"])
        #expect(out.contains("  - 视觉社会学"))
        #expect(out.contains("  - 技能知识"))
    }

    @Test func singleItemStaysAsBlockList() {
        // Per spec: avoid "single vs multi" branches. Single-item list is a
        // 1-element block list (no special-casing to scalar).
        let f = "---\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["only"])
        #expect(out.contains("themes:\n  - only"))
        #expect(!out.contains("themes: only"))
    }

    @Test func quotesReservedIndicatorPrefix() {
        // Leading `-` / `@` / `*` etc. would conflict with YAML indicators.
        let f = "---\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["-leading-dash", "@home"])
        #expect(out.contains(#"  - "-leading-dash""#))
        #expect(out.contains(#"  - "@home""#))
    }

    @Test func quotesBooleanLookalikes() {
        let f = "---\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["Yes", "no", "True"])
        #expect(out.contains(#"  - "Yes""#))
        #expect(out.contains(#"  - "no""#))
        #expect(out.contains(#"  - "True""#))
    }
}

@Suite struct FrontmatterPatchSequenceTests {

    @Test func setsArbitraryKeyAsBlockList() {
        let f = "---\ntype: paper\n---\nbody\n"
        let out = FrontmatterPatch.setSequence(f, key: "authors", values: ["A", "B"])
        #expect(out.contains("authors:\n  - A\n  - B"))
    }

    @Test func emptySequenceRemovesKey() {
        let f = "---\nauthors:\n  - Anne\n  - Bob\ntype: paper\n---\nbody\n"
        let out = FrontmatterPatch.setSequence(f, key: "authors", values: [])
        #expect(!out.contains("authors:"))
        #expect(!out.contains("- Anne"))
        #expect(!out.contains("- Bob"))
        #expect(out.contains("type: paper"))
    }

    @Test func replacesScalarValueWithBlockList() {
        // Legacy scalar key gets upgraded to block list on first write.
        let f = "---\nauthor: Sara Ahmed\ntype: paper\n---\nbody\n"
        let out = FrontmatterPatch.setSequence(f, key: "author", values: ["Sara Ahmed", "Jane Doe"])
        #expect(out.contains("author:\n  - Sara Ahmed\n  - Jane Doe"))
        #expect(!out.contains("author: Sara Ahmed"))
        #expect(out.contains("type: paper"))
    }

    @Test func consumesUnindentedBlockListContinuation() {
        // Some legacy files write block items at column 0 (also valid YAML).
        // Our scanner must consume those.
        let f = "---\nauthors:\n- Old1\n- Old2\nyear: 2020\n---\nbody\n"
        let out = FrontmatterPatch.setSequence(f, key: "authors", values: ["New"])
        #expect(out.contains("authors:\n  - New"))
        #expect(!out.contains("- Old1"))
        #expect(!out.contains("- Old2"))
        #expect(out.contains("year: 2020"))
    }

    @Test func consumesIndentedBlockListContinuation() {
        let f = "---\nauthors:\n  - Old1\n  - Old2\nyear: 2020\n---\nbody\n"
        let out = FrontmatterPatch.setSequence(f, key: "authors", values: ["New"])
        #expect(out.contains("authors:\n  - New"))
        #expect(!out.contains("- Old1"))
        #expect(out.contains("year: 2020"))
    }

    @Test func doesNotEatClosingFence() {
        // The continuation-scanner must NOT mistake `---` (frontmatter close)
        // for a block list item starting with `-`.
        let f = "---\nauthors: [Anne]\n---\nbody starts here\n"
        let out = FrontmatterPatch.setSequence(f, key: "authors", values: ["Bob"])
        #expect(out.contains("authors:\n  - Bob"))
        #expect(out.contains("---\nbody starts here"))
    }

    @Test func absentKeyAndEmptyValuesIsNoOp() {
        let f = "---\ntype: paper\n---\nbody\n"
        #expect(FrontmatterPatch.setSequence(f, key: "themes", values: []) == f)
    }

    @Test func noFrontmatterReturnsUnchanged() {
        let raw = "plain text, no fm\n"
        #expect(FrontmatterPatch.setSequence(raw, key: "themes", values: ["x"]) == raw)
    }
}

@Suite struct FrontmatterPatchRemoveKeyTests {

    @Test func removesScalarKey() {
        let f = "---\nauthor: Sara Ahmed\ntype: paper\n---\nbody\n"
        let out = FrontmatterPatch.removeKey(f, key: "author")
        #expect(!out.contains("author:"))
        #expect(out.contains("type: paper"))
    }

    @Test func removesBlockListKeyAndContinuation() {
        let f = "---\nauthors:\n  - A\n  - B\ntype: paper\n---\nbody\n"
        let out = FrontmatterPatch.removeKey(f, key: "authors")
        #expect(!out.contains("authors:"))
        #expect(!out.contains("- A"))
        #expect(!out.contains("- B"))
        #expect(out.contains("type: paper"))
    }

    @Test func absentKeyIsNoOp() {
        let f = "---\ntype: paper\n---\nbody\n"
        #expect(FrontmatterPatch.removeKey(f, key: "author") == f)
    }
}
