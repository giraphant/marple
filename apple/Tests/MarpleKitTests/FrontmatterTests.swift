import Testing
@testable import MarpleKit

@Suite struct FrontmatterTests {
    @Test func testSplitsLeadingFence() {
        let raw = "---\ntitle: X\nthemes: []\n---\n# Heading\n\nBody."
        let r = Frontmatter.split(raw)
        #expect(r.frontmatter == "title: X\nthemes: []")
        #expect(r.body == "# Heading\n\nBody.")
    }

    @Test func testNoFenceReturnsWholeBody() {
        let raw = "# Just a body\n\nNo frontmatter."
        let r = Frontmatter.split(raw)
        #expect(r.frontmatter == nil)
        #expect(r.body == raw)
    }
}
