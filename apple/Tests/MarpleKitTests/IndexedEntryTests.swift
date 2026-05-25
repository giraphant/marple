import Testing
@testable import MarpleKit

// MARK: - IndexedEntry / buildIndexedEntry tests
//
// Each test mirrors a real-world vault document shape.  The assertions encode
// the exact parity contract with Rust `build_indexed_entry` (:132-244).
//
// Fixture documents are written as raw Swift string literals with realistic
// frontmatter + body content; every asserted value is derived by hand from the
// same logic the Rust function uses.

@Suite("IndexedEntry")
struct IndexedEntryTests {

    // MARK: - Helpers

    /// Build with no sources dir (empty slug set) and no mtime.
    private func build(
        text: String,
        rel: String = "vault/papers/test.md",
        fileStem: String = "test",
        sourceSlugs: Set<String> = [],
        mtimeMs: Int64? = nil
    ) -> BuildOutcome {
        buildIndexedEntry(
            text: text,
            rel: rel,
            fileStem: fileStem,
            sourceSlugs: sourceSlugs,
            mtimeMs: mtimeMs
        )
    }

    // MARK: - Skipped cases

    @Test("no frontmatter fence → .skipped")
    func noFence() {
        let text = "Just a plain markdown file with no frontmatter."
        #expect(build(text: text) == .skipped)
    }

    @Test("incomplete fence (opening --- but no closing ---) → .skipped")
    func incompleteFence() {
        let text = "---\ntype: note\ntitle: Something\n"   // no closing ---
        #expect(build(text: text) == .skipped)
    }

    @Test("frontmatter with no type key → .skippedNoType")
    func noTypeKey() {
        let text = """
        ---
        title: No Type Here
        author: Someone
        ---

        Body content here.
        """
        #expect(build(text: text) == .skippedNoType)
    }

    @Test("type: A → .skippedUnknownType")
    func typeA() {
        let text = """
        ---
        type: A
        title: Sentinel Skip
        ---

        Body content.
        """
        #expect(build(text: text) == .skippedUnknownType)
    }

    @Test("empty type value → .skippedNoType (field_text returns None for null)")
    func typeEmpty() {
        // In Rust, `field_text(&frontmatter, "type")` returns None when the value
        // is YAML null (bare `type:` with no value).  field_text = field(...).and_then(text_value),
        // and text_value(null) = None, so the outcome is SkippedNoType.
        let text = """
        ---
        type:
        title: Empty Type
        ---

        Body.
        """
        #expect(build(text: text) == .skippedNoType)
    }

    // MARK: - Paper analysis with rating, themes, year

    @Test("paper-analysis: type alias 'paper' → canonical 'paper-analysis'")
    func paperTypeAlias() throws {
        let text = """
        ---
        type: paper
        title: Dogs and Cats in the Wild
        author: Smith, John
        year: 2019
        rating: ★★★
        themes:
          - ai
          - ethics
        ---

        This is the abstract. It covers several topics in depth.
        """
        let outcome = build(text: text, rel: "vault/papers/smith-dogs-2019.md",
                            fileStem: "smith-dogs-2019")
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.entryType == "paper-analysis")
        #expect(entry.title == "Dogs and Cats in the Wild")
        #expect(entry.author == "Smith, John")
        #expect(entry.ratingScore == 3.0)
        #expect(entry.yearJSON == "2019")
        #expect(entry.themes == ["ai", "ethics"])
        // pdfSlug for paper-analysis = fileStem
        #expect(entry.pdfSlug == "smith-dogs-2019")
        // hasPDF false — no source slugs provided
        #expect(entry.hasPDF == false)
        // preview is non-empty (body has a real paragraph)
        #expect(!entry.preview.isEmpty)
        // searchText contains part of the body
        #expect(entry.searchText.contains("abstract"))
        // path is the rel
        #expect(entry.path == "vault/papers/smith-dogs-2019.md")
        // added initialised to 0
        #expect(entry.added == 0)
        // mtime nil when not provided
        #expect(entry.mtime == nil)
        // ratingJSON — ★★★ is truthy string → JSON string
        #expect(entry.ratingJSON == "\"★★★\"")
    }

    @Test("paper-analysis: hasPDF true when slug is in sourceSlugs")
    func paperHasPDF() throws {
        let text = """
        ---
        type: paper-analysis
        title: My Paper
        ---
        Body.
        """
        let outcome = build(text: text,
                            rel: "vault/papers/smith-dogs-2019.md",
                            fileStem: "smith-dogs-2019",
                            sourceSlugs: ["smith-dogs-2019"])
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.hasPDF == true)
    }

    @Test("paper-analysis: mtime passed through")
    func paperMtime() throws {
        let text = """
        ---
        type: paper-analysis
        title: Mtime Test
        ---
        Body.
        """
        let outcome = build(text: text, fileStem: "test", mtimeMs: 1_700_000_000_000)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.mtime == 1_700_000_000_000)
    }

    // MARK: - Note: title from first heading

    @Test("note: title comes from first heading when no frontmatter title")
    func noteTitleFromHeading() throws {
        let text = """
        ---
        type: note
        ---

        # My Heading

        Some body content here.
        """
        let outcome = build(text: text, rel: "vault/notes/my-heading.md",
                            fileStem: "my-heading")
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.entryType == "note")
        #expect(entry.title == "My Heading")
    }

    @Test("note: title falls back to frontmatter 'title' when no heading")
    func noteTitleFallbackFrontmatter() throws {
        let text = """
        ---
        type: note
        title: Frontmatter Title
        ---

        No heading here, just prose.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.title == "Frontmatter Title")
    }

    @Test("note: heading takes priority over frontmatter title")
    func noteHeadingBeforeFrontmatterTitle() throws {
        let text = """
        ---
        type: note
        title: Frontmatter Title
        ---

        # Heading In Body

        Some content.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        // For note: first_heading takes priority over frontmatter title
        #expect(entry.title == "Heading In Body")
    }

    // MARK: - Book overview: titleCn from Chinese H1

    @Test("book-overview: titleCn from Chinese H1 when no title_cn frontmatter")
    func bookTitleCnFromH1() throws {
        let text = """
        ---
        type: book-overview
        title: English Title
        ---

        # 中文标题

        Body content here.
        """
        let outcome = build(text: text, rel: "vault/books/smith-book-2020/overview.md",
                            fileStem: "overview")
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.entryType == "book-overview")
        #expect(entry.titleCn == "中文标题")
        // book = nil — book-overview doesn't set `book` (only chapter-summary does)
        #expect(entry.book == nil)
    }

    @Test("book-overview: titleCn nil when Chinese H1 matches title")
    func bookTitleCnNilWhenSameAsTitle() throws {
        let text = """
        ---
        type: book-overview
        title: 中文标题
        ---

        # 中文标题

        Body.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        // firstChineseH1 returns "中文标题" but it equals title → titleCn = nil
        #expect(entry.titleCn == nil)
    }

    // MARK: - Chapter summary: book slug derived from path

    @Test("chapter-summary: book slug extracted from vault/books/... path")
    func chapterBook() throws {
        let text = """
        ---
        type: chapter
        title: Chapter One
        ---

        Chapter content here.
        """
        let outcome = build(text: text,
                            rel: "vault/books/smith-dogs-2020/ch1.md",
                            fileStem: "ch1")
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.entryType == "chapter-summary")
        #expect(entry.book == "smith-dogs-2020")
        // chapter-summary pdfSlug = nil (only paper-analysis and book-overview get pdfSlug)
        #expect(entry.pdfSlug == nil)
    }

    // MARK: - Author & multi-author flatten

    @Test("multi-author sequence flattened with ', '")
    func multiAuthor() throws {
        let text = """
        ---
        type: paper-analysis
        title: Joint Work
        authors:
          - Alice Smith
          - Bob Jones
        ---

        Content.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.author == "Alice Smith, Bob Jones")
    }

    @Test("author field takes priority over authors")
    func authorVsAuthors() throws {
        let text = """
        ---
        type: paper-analysis
        title: Test
        author: Solo Author
        authors:
          - Should Not Appear
        ---
        Content.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.author == "Solo Author")
    }

    // MARK: - Image entries

    @Test("image: indexes title author source themes from image.md")
    func imageEntryMetadata() throws {
        let text = """
        ---
        type: image
        title: AI Agent Loop Diagram
        author: Alice Example
        source: https://example.com/agent-loop
        themes:
          - AI
          - architecture
        ---

        A diagram explaining the agent loop.
        """
        let outcome = build(text: text,
                            rel: "vault/images/ai-agent-loop-diagram/image.md",
                            fileStem: "image")
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed, got \(outcome)")
            return
        }

        #expect(entry.entryType == "image")
        #expect(entry.path == "vault/images/ai-agent-loop-diagram/image.md")
        #expect(entry.title == "AI Agent Loop Diagram")
        #expect(entry.author == "Alice Example")
        #expect(entry.source == "https://example.com/agent-loop")
        #expect(entry.themes == ["AI", "architecture"])
        #expect(entry.hasPDF == false)
        #expect(entry.pdfSlug == nil)
        #expect(entry.searchText.contains("AI Agent Loop Diagram"))
        #expect(entry.searchText.contains("Alice Example"))
        #expect(entry.searchText.contains("agent loop"))
    }

    // MARK: - Optional fields: topic, source, doi, publisher, isbn

    @Test("optional metadata fields populated correctly")
    func optionalFields() throws {
        let text = """
        ---
        type: paper-analysis
        title: Comprehensive Paper
        author: Jones
        year: 2021
        topic: cognitive science
        source: Nature
        doi: 10.1234/test
        publisher: MIT Press
        isbn: 978-0-262-12345-6
        ---

        Abstract content here.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.topic == "cognitive science")
        #expect(entry.source == "Nature")
        #expect(entry.doi == "10.1234/test")
        #expect(entry.publisher == "MIT Press")
        #expect(entry.isbn == "978-0-262-12345-6")
    }

    // MARK: - yearJSON and ratingJSON field shapes

    @Test("yearJSON: integer year → JSON number string")
    func yearJSONInteger() throws {
        let text = """
        ---
        type: note
        year: 2023
        ---
        Body.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.yearJSON == "2023")
    }

    @Test("yearJSON: string year → JSON string")
    func yearJSONString() throws {
        let text = """
        ---
        type: note
        year: "2023"
        ---
        Body.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.yearJSON == "\"2023\"")
    }

    @Test("ratingJSON: false → nil (truthy filter)")
    func ratingJSONFalsy() throws {
        let text = """
        ---
        type: note
        rating: false
        ---
        Body.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.ratingJSON == nil)
        #expect(entry.ratingScore == 0.0)
    }

    @Test("ratingJSON: numeric 4 → JSON number, ratingScore 4.0")
    func ratingNumeric() throws {
        let text = """
        ---
        type: note
        rating: 4
        ---
        Body.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.ratingJSON == "4")
        #expect(entry.ratingScore == 4.0)
    }

    // MARK: - bodyLen

    @Test("bodyLen counts unicode scalars of normalized body")
    func bodyLenField() throws {
        let body = "Line one.\n\nLine two."
        let text = """
        ---
        type: note
        ---

        \(body)
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        // normalizeBodyForSearch("Line one.\n\nLine two.") = "Line one.\nLine two." → 19 scalars
        #expect(entry.bodyLen == Int64(normalizeBodyForSearch(body).unicodeScalars.count))
    }

    // MARK: - searchText composition

    @Test("searchText contains rel, title, and normalized body")
    func searchTextComposition() throws {
        let text = """
        ---
        type: paper-analysis
        title: Unique Paper Title
        ---

        Searchable body text with unique phrase zyzzyva.
        """
        let outcome = build(text: text, rel: "vault/papers/unique-path-xyz.md",
                            fileStem: "unique-path-xyz")
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.searchText.contains("vault/papers/unique-path-xyz.md"))
        #expect(entry.searchText.contains("Unique Paper Title"))
        #expect(entry.searchText.contains("zyzzyva"))
    }

    // MARK: - Translation fields

    @Test("translationTitleCn from localisations.zh.title")
    func translationTitleCn() throws {
        let text = """
        ---
        type: book-overview
        title: The Origin of Species
        localisations:
          zh:
            title: 物种起源
            douban_url: "12345678"
        ---

        Darwin's landmark work.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.translationTitleCn == "物种起源")
        #expect(entry.translationDoubanURL == "https://book.douban.com/subject/12345678/")
    }

    // MARK: - chaptersAnalyzed and annotates

    @Test("chaptersAnalyzed and annotates populated")
    func chaptersAnalyzedAndAnnotates() throws {
        let text = """
        ---
        type: book-overview
        title: A Big Book
        chapters_analyzed: 12
        annotates: vault/sources/big-book.md
        ---

        Overview content.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.chaptersAnalyzed == 12)
        #expect(entry.annotates == "vault/sources/big-book.md")
    }

    // MARK: - created field

    @Test("created field preserved as text")
    func createdField() throws {
        let text = """
        ---
        type: note
        created: 2024-01-15
        ---

        Some note.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.created == "2024-01-15")
    }

    // MARK: - titleEn

    @Test("titleEn extracted from title_en field")
    func titleEnField() throws {
        let text = """
        ---
        type: book-overview
        title: 机器学习
        title_en: Machine Learning
        ---

        Body.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.titleEn == "Machine Learning")
    }

    // MARK: - bodyText stored on entry

    @Test("bodyText is normalized body stored on entry")
    func bodyTextField() throws {
        let text = """
        ---
        type: note
        ---

        Hello world.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.bodyText == "Hello world.")
    }

    // MARK: - type aliases

    @Test("type alias 'book' → 'book-overview'")
    func typeAliasBook() throws {
        let text = """
        ---
        type: book
        title: Some Book
        ---
        Body.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.entryType == "book-overview")
    }

    @Test("type alias 'book_chapter' → 'chapter-summary'")
    func typeAliasBookChapter() throws {
        let text = """
        ---
        type: book_chapter
        title: A Chapter
        ---
        Body.
        """
        let outcome = build(text: text,
                            rel: "vault/books/some-book-2020/ch2.md",
                            fileStem: "ch2")
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.entryType == "chapter-summary")
        #expect(entry.book == "some-book-2020")
    }

    @Test("unknown non-empty type passed through unchanged")
    func typeUnknownPassthrough() throws {
        let text = """
        ---
        type: my-custom-type
        title: Custom
        ---
        Body.
        """
        let outcome = build(text: text)
        guard case .indexed(let entry) = outcome else {
            Issue.record("Expected .indexed"); return
        }
        #expect(entry.entryType == "my-custom-type")
    }
}
