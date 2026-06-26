import Testing
@testable import MarpleKit

@Suite struct MarkdownBodyTests {
    @Test func replacesBodyAndPreservesFrontmatter() {
        let raw = """
        ---
        type: note
        title: Old
        annotates: vault/papers/p.md
        ---

        Old body
        """
        let replaced = MarkdownBody.replace(in: raw, with: "New body\n\n- item")
        #expect(replaced == """
        ---
        type: note
        title: Old
        annotates: vault/papers/p.md
        ---

        New body

        - item

        """)
    }

    @Test func replacesWholeTextWhenNoFrontmatter() {
        #expect(MarkdownBody.replace(in: "Old body", with: "New body") == "New body\n")
    }

    @Test func emptyBodyKeepsLegalFrontmatterDocument() {
        let raw = """
        ---
        type: note
        ---

        Body
        """
        #expect(MarkdownBody.replace(in: raw, with: "\n") == "---\ntype: note\n---\n\n")
    }
}
