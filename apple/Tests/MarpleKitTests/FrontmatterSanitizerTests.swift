import Testing
@testable import MarpleKit

@Suite struct FrontmatterSanitizerBodyTests {

    @Test func stripsEmptyBracketHashTail() {
        let inner = "type: paper\nthemes: [](#)\n"
        let out = FrontmatterSanitizer.sanitizeBody(inner)
        #expect(out.contains("themes: []"))
        #expect(!out.contains("[](#)"))
    }

    @Test func stripsEmptyParens() {
        let inner = "themes: []()\n"
        #expect(FrontmatterSanitizer.sanitizeBody(inner).contains("themes: []"))
    }

    @Test func stripsCJKValueHashTail() {
        let inner = "themes: [标准化](#)\n"
        let out = FrontmatterSanitizer.sanitizeBody(inner)
        #expect(out.contains("themes: [标准化]"))
        #expect(!out.contains("(#)"))
    }

    @Test func stripsMultiItemFlowArrayTail() {
        let inner = "themes: [a, b](#)\n"
        #expect(FrontmatterSanitizer.sanitizeBody(inner).contains("themes: [a, b]"))
    }

    @Test func stripsNonHashUrl() {
        let inner = "themes: [text](url)\n"
        #expect(FrontmatterSanitizer.sanitizeBody(inner).contains("themes: [text]"))
    }

    @Test func stripsAuthorKey() {
        let inner = "author: [Sara Ahmed](#)\n"
        #expect(FrontmatterSanitizer.sanitizeBody(inner).contains("author: [Sara Ahmed]"))
    }

    @Test func stripsAuthorsKey() {
        let inner = "authors: [A, B](#)\n"
        #expect(FrontmatterSanitizer.sanitizeBody(inner).contains("authors: [A, B]"))
    }

    @Test func leavesUnknownKeyAlone() {
        // `tags` is not on the list-keys allowlist; user might genuinely have
        // a markdown link in there. Don't touch it.
        let inner = "tags: [a, b](#)\n"
        let out = FrontmatterSanitizer.sanitizeBody(inner)
        #expect(out.contains("tags: [a, b](#)"))
    }

    @Test func leavesIndentedKeyAlone() {
        let inner = "nested:\n  themes: [a, b](#)\n"
        // Indented key isn't top-level — sanitizer skips it.
        let out = FrontmatterSanitizer.sanitizeBody(inner)
        #expect(out.contains("themes: [a, b](#)"))
    }

    @Test func leavesBlockListContinuationAlone() {
        // Block list items are line-by-line; Ulysses doesn't bite them. Leave
        // any inline markdown they contain alone.
        let inner = "themes:\n  - foo\n  - bar\n"
        #expect(FrontmatterSanitizer.sanitizeBody(inner) == inner)
    }

    @Test func idempotentOnClean() {
        let inner = "type: paper\nthemes: [a, b]\n"
        #expect(FrontmatterSanitizer.sanitizeBody(inner) == inner)
    }

    @Test func preservesNonTargetLines() {
        let inner = "type: paper\ntitle: foo\nthemes: [a](#)\nyear: 2020\n"
        let out = FrontmatterSanitizer.sanitizeBody(inner)
        #expect(out.contains("title: foo"))
        #expect(out.contains("year: 2020"))
        #expect(out.contains("themes: [a]"))
    }
}

@Suite struct FrontmatterSanitizerFullFileTests {

    @Test func stripsDamageWithinFencesLeavesBodyAlone() {
        let raw = """
        ---
        type: paper
        themes: [a, b](#)
        ---

        Body with a real markdown link: [click](https://example.com).
        Should NOT be touched.
        """
        let out = FrontmatterSanitizer.sanitize(raw)
        #expect(out.contains("themes: [a, b]"))
        #expect(out.contains("[click](https://example.com)"))
    }

    @Test func returnsOriginalWhenNoFrontmatter() {
        let raw = "no fm here, [a](#) in body\n"
        #expect(FrontmatterSanitizer.sanitize(raw) == raw)
    }

    @Test func returnsOriginalWhenNoClosingFence() {
        let raw = "---\ntype: paper\nthemes: [a](#)\n"
        // No closing fence — sanitizer treats as malformed and bails.
        #expect(FrontmatterSanitizer.sanitize(raw) == raw)
    }

    @Test func idempotentOnAlreadyClean() {
        let raw = "---\ntype: paper\nthemes: [a, b]\n---\nbody\n"
        #expect(FrontmatterSanitizer.sanitize(raw) == raw)
    }

    @Test func parseMappingHandlesDamagedInput() {
        // End-to-end: parseMapping should now successfully parse damaged input
        // because sanitizer cleans it first.
        let damaged = "type: paper\nthemes: [a, b](#)\n"
        let parsed = YamlFrontmatter.parseMapping(damaged)
        #expect(parsed.contains(where: { $0.0 == "type" }))
        #expect(parsed.contains(where: { $0.0 == "themes" }))
        guard case let .sequence(items)? = parsed.first(where: { $0.0 == "themes" })?.1 else {
            Issue.record("themes should parse as a sequence after sanitization")
            return
        }
        #expect(items.count == 2)
    }
}
