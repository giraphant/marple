import Testing
@testable import MarpleKit

@Suite struct CitationTests {
    /// Test factory — accepts a legacy joined-string `author` for terseness;
    /// `splitAuthors` converts it to the canonical `[String]` on construction.
    private func entry(author: String? = nil, year: String? = nil, title: String? = nil,
                       source: String? = nil, doi: String? = nil) -> Entry {
        Entry(path: "p.md", type: .paperAnalysis, title: title,
              author: splitAuthors(author),
              year: year, ratingScore: 0, themes: [], preview: "", hasPDF: false,
              source: source, doi: doi)
    }

    // MARK: lastname

    @Test func lastnameFromCommaForm() { #expect(lastname("Clark, Andy") == "Clark") }
    @Test func lastnameFromFirstLast() { #expect(lastname("Andy Clark") == "Clark") }
    @Test func lastnameFromMiddleInitial() { #expect(lastname("First M. Last") == "Last") }
    @Test func lastnameCJKKeptWhole() { #expect(lastname("张三") == "张三") }
    @Test func lastnameEmpty() { #expect(lastname("   ") == "") }

    // MARK: splitAuthors

    @Test func splitOnAmpersand() {
        #expect(splitAuthors("Clark & Chalmers") == ["Clark", "Chalmers"])
    }
    @Test func splitOnAnd() {
        #expect(splitAuthors("Clark AND Chalmers") == ["Clark", "Chalmers"])
    }
    @Test func splitOnComma() {
        #expect(splitAuthors("Clark, Chalmers") == ["Clark", "Chalmers"])
    }
    @Test func splitNilIsEmpty() { #expect(splitAuthors(nil).isEmpty) }

    // MARK: inline-en

    @Test func inlineENSingle() {
        #expect(buildCitation(entry(author: "Andy Clark", year: "1998"), format: .inlineEN) == "(Clark, 1998)")
    }
    @Test func inlineENTwoAuthors() {
        #expect(buildCitation(entry(author: "Clark & Chalmers", year: "1998"), format: .inlineEN) == "(Clark & Chalmers, 1998)")
    }
    @Test func inlineENThreePlusUsesEtAl() {
        #expect(buildCitation(entry(author: "Clark & Chalmers & Dennett", year: "1998"), format: .inlineEN) == "(Clark et al., 1998)")
    }
    @Test func inlineENYearOnly() {
        #expect(buildCitation(entry(year: "1998"), format: .inlineEN) == "(1998)")
    }
    @Test func inlineENAuthorOnly() {
        #expect(buildCitation(entry(author: "Andy Clark"), format: .inlineEN) == "(Clark)")
    }
    @Test func inlineENEmptyWhenNothing() {
        #expect(buildCitation(entry(title: "Being There"), format: .inlineEN) == "")
    }

    // MARK: inline-zh

    @Test func inlineZHFullWidth() {
        #expect(buildCitation(entry(author: "Andy Clark", year: "1998"), format: .inlineZH) == "（Clark，1998）")
    }
    @Test func inlineZHTwoAuthors() {
        #expect(buildCitation(entry(author: "Clark & Chalmers", year: "1998"), format: .inlineZH) == "（Clark、Chalmers，1998）")
    }
    @Test func inlineZHThreePlus() {
        #expect(buildCitation(entry(author: "Clark & Chalmers & Dennett", year: "1998"), format: .inlineZH) == "（Clark 等，1998）")
    }

    // MARK: title

    @Test func titleFormat() {
        #expect(buildCitation(entry(title: "Being There"), format: .title) == "Being There")
    }

    // MARK: markdown

    @Test func markdownFull() {
        let e = entry(author: "Andy Clark", year: "1998", title: "Being There", source: "MIT Press")
        #expect(buildCitation(e, format: .markdown) == "Andy Clark (1998). *Being There*. MIT Press.")
    }
    @Test func markdownWithDOI() {
        let e = entry(author: "Andy Clark", year: "1998", title: "Being There", doi: "10.1/x")
        #expect(buildCitation(e, format: .markdown) == "Andy Clark (1998). *Being There*. https://doi.org/10.1/x")
    }
    @Test func markdownTitleOnly() {
        #expect(buildCitation(entry(title: "Being There"), format: .markdown) == "*Being There*.")
    }
}
