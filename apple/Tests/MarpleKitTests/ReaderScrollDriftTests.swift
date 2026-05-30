import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

/// QUA-151 阅读器高度漂移: switching documents must not inherit the previous
/// document's scroll position, but switching *back* to a tab must restore its own.
/// Two seams cover the fix:
///  - `MarkdownTextView.shouldRepositionOnDocSwitch` decides which render owns the
///    per-doc reposition (restore remembered offset, else top).
///  - `AppModel` must clear the leftover outline `scrollTarget` on navigation.
@Suite struct ReaderScrollDriftTests {

    // MARK: - doc-switch reposition precedence (pure decision)

    @Test func docSwitchWithNoTargetRepositions() {
        // A genuine doc switch with nothing else driving scroll → this render owns
        // the reposition (restore the doc's offset, or top if first visit).
        #expect(MarkdownTextView.shouldRepositionOnDocSwitch(
            docSwitched: true, hasScrollTarget: false, hasPendingJump: false))
    }

    @Test func sameDocumentNeverRepositions() {
        // A style-only update or an FSEvents reload must leave scroll alone.
        #expect(!MarkdownTextView.shouldRepositionOnDocSwitch(
            docSwitched: false, hasScrollTarget: false, hasPendingJump: false))
    }

    @Test func outlineTargetTakesPrecedence() {
        // Opening straight to an outline heading: the target drives scroll.
        #expect(!MarkdownTextView.shouldRepositionOnDocSwitch(
            docSwitched: true, hasScrollTarget: true, hasPendingJump: false))
    }

    @Test func searchJumpTakesPrecedence() {
        // Opening a clicked search match: the jump drives scroll.
        #expect(!MarkdownTextView.shouldRepositionOnDocSwitch(
            docSwitched: true, hasScrollTarget: false, hasPendingJump: true))
    }

    // MARK: - model clears stale outline target on navigation

    @MainActor
    @Test func openClearsLeftoverScrollTarget() async {
        let a = Entry(path: "vault/notes/a.md", type: .note, title: "A", author: [],
                      year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let b = Entry(path: "vault/notes/b.md", type: .note, title: "B", author: [],
                      year: nil, ratingScore: 0, themes: [], preview: "", hasPDF: false)
        let client = StubVaultClient(
            entries: [a, b],
            texts: ["vault/notes/a.md": "# A\n\nbody", "vault/notes/b.md": "# B\n\nbody"])
        let model = AppModel(client: client)
        await model.loadIndex()

        await model.open(a.path)
        // Simulate an inspector outline tap deep in document A.
        model.scrollTarget = 7
        #expect(model.scrollTarget == 7)

        // Switching to a different document must drop that stale target.
        await model.open(b.path)
        #expect(model.scrollTarget == nil)
    }
}
