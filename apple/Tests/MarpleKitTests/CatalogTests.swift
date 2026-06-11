import Testing
@testable import MarpleKit

@MainActor @Suite struct CatalogTests {
    @Test func themeIndexStoresAndReads() {
        let c = Catalog()
        c.themeIndex = [ThemeCount(theme: "存在主义", count: 3)]
        #expect(c.themeIndex.count == 1)
        #expect(c.themeIndex.first?.theme == "存在主义")
    }
}
