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

    @Test func preservesBodyParensExactly() {
        // Real markdown bodies often contain parentheses inside or around
        // links: nested footnote `(see [a](#ref))`, function signatures
        // `foo(bar)`, citations `(Ahmed, 2010)`. None of these should be
        // touched.
        let raw = """
        ---
        type: paper
        themes: [a](#)
        ---

        See [Ahmed (2010)](https://example.com/x?y=(z)) for context.
        Citation: (Ahmed, 2010, pp. 12-15).
        Code: foo(bar, baz(qux)).
        """
        let out = FrontmatterSanitizer.sanitize(raw)
        #expect(out.contains("themes: [a]"))
        #expect(out.contains("[Ahmed (2010)](https://example.com/x?y=(z))"))
        #expect(out.contains("(Ahmed, 2010, pp. 12-15)"))
        #expect(out.contains("foo(bar, baz(qux))"))
    }

    @Test func handlesCRLFFrontmatter() {
        // Windows-style line endings should still allow fence detection.
        let raw = "---\r\ntype: paper\r\nthemes: [a, b](#)\r\n---\r\nbody\r\n"
        let out = FrontmatterSanitizer.sanitize(raw)
        #expect(out.contains("themes: [a, b]"))
        #expect(!out.contains("(#)"))
    }

    /// QUA-108 + QUA-109 work together: a Ulysses-bitten vault file with
    /// `author: [A, B](#)` should sanitize → parse as a 2-element list →
    /// when rewritten via `setSequence` come back as canonical block-list →
    /// re-parse to the same list. Idempotency confirms the read+write
    /// pipeline doesn't drift.
    @Test func qua108Plus109RoundTrip() {
        let damaged = """
        ---
        type: paper
        title: Foo
        author: [Smith, John Jr.](#)
        year: 2020
        ---

        body content.
        """
        // Step 1: sanitize + YAML parse → list.
        let (rawFm, _) = Frontmatter.split(damaged)
        let parsed = YamlFrontmatter.parseMapping(rawFm ?? "")
        let authors = parseAuthors(parsed.first(where: { $0.0 == "author" })?.1)
        // Yams parses `[Smith, John Jr.]` (after sanitizer strip) as a 2-element
        // flow sequence — accepted QUA-109 lossy behavior for legacy flow form.
        #expect(authors == ["Smith", "John Jr."])

        // Step 2: rewrite the cleaned author list back as canonical block.
        let rewritten = FrontmatterPatch.setSequence(damaged, key: "author", values: authors)
        #expect(rewritten.contains("author:\n  - Smith\n  - John Jr."))
        #expect(!rewritten.contains("[](#)"))
        #expect(!rewritten.contains("[Smith"))

        // Step 3: re-parse the rewritten file — should be idempotent on the
        // author list (block sequence in, block sequence out).
        let (rawFm2, _) = Frontmatter.split(rewritten)
        let parsed2 = YamlFrontmatter.parseMapping(rawFm2 ?? "")
        let authors2 = parseAuthors(parsed2.first(where: { $0.0 == "author" })?.1)
        #expect(authors2 == authors)
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
