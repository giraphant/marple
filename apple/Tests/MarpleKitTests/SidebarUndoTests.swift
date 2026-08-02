import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct SidebarUndoTests {
    @MainActor
    @Test func groupingTemporaryPagesPinsThemInVisualOrder() async throws {
        let first = sidebarEntry("papers/first.md")
        let second = sidebarEntry("papers/second.md")
        let third = sidebarEntry("papers/third.md")
        let model = AppModel(client: StubVaultClient(
            entries: [first, second, third],
            texts: [first.path: "# First", second.path: "# Second", third.path: "# Third"]))
        await model.loadIndex()
        await model.open(first.path)
        let firstID = try #require(model.activeTabID)
        await model.openInNewTab(second.path)
        let secondID = try #require(model.activeTabID)
        await model.openInNewTab(third.path)

        model.groupTabs([secondID, firstID])

        let group = try #require(model.tabGroups.first)
        #expect(model.tabs(in: group.id).map(\.id) == [firstID, secondID])
        #expect(model.tabs(in: group.id).allSatisfy { $0.pinned })
        #expect(model.pinnedTabRootNodes == [.group(group)])
        #expect(model.temporaryTabs.map(\.location.openPath) == [third.path])
    }
}

private func sidebarEntry(_ path: String) -> Entry {
    Entry(path: path, type: .paper, title: path, author: [], year: nil,
          ratingScore: 0, themes: [], preview: "", hasPDF: false)
}
