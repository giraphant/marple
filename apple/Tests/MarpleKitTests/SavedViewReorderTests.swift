import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

/// Sidebar drag-reorder of saved views (QUA-210). The coordinator resolves the
/// drop to a slot index among the rows (counted before removal, same semantics
/// as the type-bucket reorder) and hands it to `moveSavedView` — these pin the
/// slot math.
@Suite struct SavedViewReorderTests {
    @MainActor
    private func modelWithViews(_ names: [String]) -> (AppModel, [UUID]) {
        let model = AppModel(client: StubVaultClient(entries: [], texts: [:]))
        let ids = names.map { model.createSavedView(named: $0).id }
        return (model, ids)
    }

    @MainActor
    @Test func moveDownAccountsForOwnRemoval() {
        let (model, ids) = modelWithViews(["a", "b", "c"])
        // Drop "a" into the slot below "b" (slot 2, counted with "a" still in place).
        #expect(model.moveSavedView(ids[0], to: 2))
        #expect(model.savedViews.map(\.name) == ["b", "a", "c"])
    }

    @MainActor
    @Test func moveUpUsesSlotDirectly() {
        let (model, ids) = modelWithViews(["a", "b", "c"])
        // Drop "c" into the top slot.
        #expect(model.moveSavedView(ids[2], to: 0))
        #expect(model.savedViews.map(\.name) == ["c", "a", "b"])
    }

    @MainActor
    @Test func moveToEndSlotLandsLast() {
        let (model, ids) = modelWithViews(["a", "b", "c"])
        // Slot 3 is below the last row.
        #expect(model.moveSavedView(ids[0], to: 3))
        #expect(model.savedViews.map(\.name) == ["b", "c", "a"])
    }

    @MainActor
    @Test func unknownIDIsRejected() {
        let (model, _) = modelWithViews(["a", "b"])
        #expect(!model.moveSavedView(UUID(), to: 0))
        #expect(model.savedViews.map(\.name) == ["a", "b"])
    }
}
