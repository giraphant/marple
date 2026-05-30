import Testing
import Foundation
@testable import MarpleKit

@Suite struct TabShareManifestTests {
    @Test func testSingleTabIsOneBulletNoHeader() {
        let md = renderTabShareManifest([
            .tab(name: nil, title: "Attention Is All You Need",
                 absolutePath: "/vault/papers/vaswani-2017.md")
        ])
        #expect(md == "- **Attention Is All You Need** — `/vault/papers/vaswani-2017.md`")
    }

    @Test func testCustomTabNameShowsBothNameAndTitle() {
        let md = renderTabShareManifest([
            .tab(name: "我的起点", title: "Attention Is All You Need",
                 absolutePath: "/vault/papers/vaswani-2017.md")
        ])
        #expect(md == "- **我的起点** — *Attention Is All You Need* — `/vault/papers/vaswani-2017.md`")
    }

    @Test func testCustomNameEqualToTitleCollapsesToTitleOnly() {
        let md = renderTabShareManifest([
            .tab(name: "Same", title: "Same", absolutePath: "/vault/x.md")
        ])
        #expect(md == "- **Same** — `/vault/x.md`")
    }

    @Test func testNonDocumentTabHasNoPathClause() {
        let md = renderTabShareManifest([
            .tab(name: nil, title: "笔记", absolutePath: nil)
        ])
        #expect(md == "- **笔记**")
    }

    @Test func testGroupBecomesHeaderWithNestedBulletList() {
        let md = renderTabShareManifest([
            .group(name: "深度学习综述", children: [
                .tab(name: nil, title: "ResNet", absolutePath: "/vault/papers/resnet.md"),
                .group(name: "训练技巧", children: [
                    .tab(name: nil, title: "BatchNorm", absolutePath: "/vault/papers/bn.md")
                ])
            ])
        ])
        let expected = """
        # 深度学习综述

        - **ResNet** — `/vault/papers/resnet.md`
        - 训练技巧/
          - **BatchNorm** — `/vault/papers/bn.md`
        """
        #expect(md == expected)
    }
}
