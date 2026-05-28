import Testing
@testable import Marple
@testable import MarpleKit

@Suite struct IndexLoadingPresentationTests {
    @Test func browseColumnShowsLoadingDuringAnyBootstrap() {
        #expect(IndexLoadingPresentation(isBootstrapping: true, isFirstRun: false).title == "正在加载索引")
        #expect(IndexLoadingPresentation(isBootstrapping: true, isFirstRun: true).title == "首次建立索引")
        #expect(IndexLoadingPresentation(isBootstrapping: false, isFirstRun: true).title == nil)
    }

    @MainActor
    @Test func sidebarDoesNotRenderIndexFooter() {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]), isFirstRun: false)
        model.beginRefreshing()

        let bodyType = String(reflecting: type(of: SidebarView(model: model).body))

        #expect(bodyType.contains("SidebarOutlineView"))
        #expect(!bodyType.contains("BootStatusRow"))
    }
}
