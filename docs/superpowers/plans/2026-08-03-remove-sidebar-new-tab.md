# Remove Sidebar New Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the sidebar New Tab control, vertically center the conditional fixed/temporary divider, and remove `关闭其他页面` globally.

**Architecture:** Keep the existing `.pinned` and `.tabs` outline sections and their drag/drop behavior. Render a divider cell for `.tabs` only when both page lists contain items; otherwise return no cell and use `CGFloat.leastNormalMagnitude`. Present `.tabs` as a non-group structural row so AppKit adds no source-list group spacing, hide its disclosure cell, and delete the two `关闭其他页面` UI entries plus their now-unused model operation, undo test, and localization.

**Tech Stack:** Swift 6, AppKit `NSOutlineView` and `NSBox`, Swift Testing, Swift Package Manager.

## Global Constraints

- Work directly on `main`; do not create a branch or worktree.
- Keep `.pinned` and `.tabs` as separate root sections with their existing stable keys, expansion state, children, and drag/drop routing.
- Keep the `.pinned` section's sole visible title as `页面`; never render the `.tabs` text title.
- Show the divider only when fixed and temporary pages are both present; otherwise the `.tabs` section returns no cell and adds no visible geometry. AppKit rejects literal zero table-row heights, so retain the structural row at `CGFloat.leastNormalMagnitude`.
- Never report `.tabs` as an AppKit group item and never show its outline disclosure cell. Its row rectangle must directly follow the preceding visible row; when shown, its 13-point divider cell sits between the two page lists with 6.5 points on each side of the line.
- Remove the sidebar New Tab button, its action, and its `新建页面` / `New Tab` localization. Do not change the existing Command-T command.
- Remove `关闭其他页面` from both the AppKit sidebar and `TabStripView`, then remove the unreferenced `AppModel.closeOtherTabs(_:)`, its dedicated undo test, and its localization. Keep ordinary close, Command-W withdrawal, and explicit multi-selection close unchanged.
- Do not change `Workspace`, `NavTab`, `PersistedState`, undo/redo for remaining actions, pinning, grouping, ordering, page activation, or fixed-anchor behavior.
- Do not add `Clear`, Peek, hover-close, a synthetic outline node, new state, or defensive fallbacks.
- Preserve the empty `.pinned` section as an expandable single/batch drop target.
- Limit production and test changes to the six files listed below; workflow spec/plan documents are excluded. Preserve unrelated content.
- Build and launch only the cache-backed development bundle; do not overwrite `/Applications/Marple.app`, sign, push, publish, or create a release.

---

## File Map

- Modify `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`: specify the button-free four states, remove the obsolete command-palette button test, and retain the real empty-section drop regression.
- Modify `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`: replace `SidebarNewTabCellView`, remove group-row spacing/disclosure from `.tabs`, and remove the close-others menu entry/selector.
- Modify `apple/Sources/Marple/Tabs/TabStripView.swift`: remove the close-others context-menu entry.
- Modify `apple/Sources/Marple/App/AppModel.swift`: remove the now-unreferenced `closeOtherTabs(_:)` operation.
- Modify `apple/Tests/MarpleKitTests/SidebarUndoTests.swift`: remove only the dedicated close-others undo test.
- Modify `apple/Sources/Marple/Resources/Localizable.xcstrings`: remove the now-unused `新建页面` and `关闭其他页面` keys.

---

### Task 1: Finalize Sidebar Page Presentation and Simplify Tab Closing

**Files:**
- Modify: `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`
- Modify: `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift:551-558, 686-711, 1827-1891`
- Modify: `apple/Sources/Marple/Tabs/TabStripView.swift:145-148`
- Modify: `apple/Sources/Marple/App/AppModel.swift:1736-1744`
- Modify: `apple/Tests/MarpleKitTests/SidebarUndoTests.swift:219-239`
- Modify: `apple/Sources/Marple/Resources/Localizable.xcstrings`

**Interfaces:**
- Keeps: `SidebarOutlineNode.Kind.section(.pinned/.tabs)` and both sections' existing children, selection, expansion, payload, and drop semantics.
- Produces: private `Coordinator.showsPageDivider: Bool`.
- Produces: private `SidebarPageDividerCellView` with constant `height: CGFloat`.
- Removes: private `SidebarNewTabCellView` button/coordinator action and localization key `新建页面`.
- Removes: both `关闭其他页面` UI entries, `closeOtherTabsFromMenu(_:)`, `AppModel.closeOtherTabs(_:)`, its dedicated undo test, and localization key.

- [ ] **Step 1: Change the layout test first**

Add the expected divider state to `LayoutCase`:

```swift
private struct LayoutCase {
    let name: String
    let hasFixed: Bool
    let hasTemporary: Bool
    let expectedRows: [String]
    let expectedDivider: Bool
}
```

Replace the four cases with the approved button-free order:

```swift
let cases = [
    LayoutCase(name: "empty", hasFixed: false, hasTemporary: false,
               expectedRows: [pageTitle], expectedDivider: false),
    LayoutCase(name: "temporary-only", hasFixed: false, hasTemporary: true,
               expectedRows: [pageTitle, "Temporary"], expectedDivider: false),
    LayoutCase(name: "fixed-only", hasFixed: true, hasTemporary: false,
               expectedRows: [pageTitle, "Fixed"], expectedDivider: false),
    LayoutCase(name: "both", hasFixed: true, hasTemporary: true,
               expectedRows: [pageTitle, "Fixed", "Temporary"], expectedDivider: true),
]
```

Change the assertions so the same integration test rejects both an orphan divider and any remaining New Tab button:

```swift
#expect(rendered.rows == item.expectedRows, Comment(rawValue: item.name))
#expect(rendered.dividerVisible == item.expectedDivider, Comment(rawValue: item.name))
#expect(rendered.dividerCellExists == item.expectedDivider, Comment(rawValue: item.name))
#expect(rendered.newTabButtonCount == 0, Comment(rawValue: item.name))
if item.expectedDivider {
    #expect(rendered.dividerRowHeight == 13, Comment(rawValue: item.name))
} else {
    #expect(rendered.dividerRowHeight == CGFloat.leastNormalMagnitude,
            Comment(rawValue: item.name))
}
if item.hasTemporary {
    let expectedOffset: CGFloat = item.expectedDivider ? 13 : 0
    #expect(rendered.temporaryRowOffset == expectedOffset,
            Comment(rawValue: item.name))
} else {
    #expect(rendered.temporaryRowOffset == nil, Comment(rawValue: item.name))
}
```

Remove `try` from the `renderedPageArea` call, then change the rendered snapshot to keep only values relevant to the final UI:

```swift
@MainActor
private struct RenderedPageArea {
    let rows: [String]
    let dividerVisible: Bool
    let dividerCellExists: Bool
    let dividerRowHeight: CGFloat
    let temporaryRowOffset: CGFloat?
    let newTabButtonCount: Int
}

@MainActor
private func renderedPageArea(in outline: NSOutlineView) -> RenderedPageArea {
    let pageTitle = String(localized: "页面")
    let newTabTitle = String(localized: "新建页面")
    var rows: [String] = []
    var temporaryRow: Int?
    var newTabButtonCount = 0

    for row in 0..<outline.numberOfRows {
        guard let view = outline.view(
            atColumn: 0, row: row, makeIfNecessary: true) else { continue }
        let text = descendants(of: NSTextField.self, in: view).map(\.stringValue)
        if text.contains(pageTitle) { rows.append(pageTitle) }
        if text.contains("Fixed") { rows.append("Fixed") }
        if text.contains("Temporary") {
            rows.append("Temporary")
            temporaryRow = row
        }
        newTabButtonCount += descendants(of: NSButton.self, in: view)
            .filter { $0.title == newTabTitle }.count
    }

    let dividerRow = temporaryRow.map { $0 - 1 } ?? outline.numberOfRows - 1
    let dividerView = outline.view(
        atColumn: 0, row: dividerRow, makeIfNecessary: true)
    let dividers = dividerView.map { descendants(of: NSBox.self, in: $0) } ?? []
    let dividerRect = outline.rect(ofRow: dividerRow)

    return RenderedPageArea(
        rows: rows,
        dividerVisible: dividers.contains {
            $0.boxType == .separator && !$0.isHidden
        },
        dividerCellExists: dividerView != nil,
        dividerRowHeight: dividerRect.height,
        temporaryRowOffset: temporaryRow.map {
            outline.rect(ofRow: $0).minY - dividerRect.minY
        },
        newTabButtonCount: newTabButtonCount)
}
```

Leave `newTabOpensGlobalSearchWithoutBecomingAPage` in place for the RED run. It describes behavior that production still has at this point and will be deleted only after the replacement behavior fails correctly.

- [ ] **Step 2: Run the focused suite and verify RED**

Run from `apple/`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter SidebarPageSectionTests --quiet \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected RED: `pageAreaRendersTheFourApprovedStates` reports the extra `新建页面` row/button, a cell in every state, an unexpected divider for `temporary-only`, and the old 30/46-point section geometry instead of no geometry/13 points. The existing New Tab action test still passes, proving the failure comes from the newly specified removal rather than broken test setup.

- [ ] **Step 3: Add one shared divider condition**

Beside `pinnedRootItems` and `temporaryItems` in `Coordinator`, add:

```swift
private var showsPageDivider: Bool {
    !pinnedRootItems.isEmpty && !temporaryItems.isEmpty
}
```

This is view-derived state only; do not add a stored property or persist it.

- [ ] **Step 4: Replace the `.tabs` section rendering**

Update the `.tabs` row height and view special case:

```swift
func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    guard let node = item as? SidebarOutlineNode else { return 30 }
    switch node.kind {
    case .section(.tabs):
        return showsPageDivider
            ? SidebarPageDividerCellView.height
            : CGFloat.leastNormalMagnitude
    case .section:
        return 22
    case .pane:
        return 30
    case .tab, .group:
        return 30
    }
}

func outlineView(_ outlineView: NSOutlineView,
                 viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let node = item as? SidebarOutlineNode else { return nil }
    if node.isTabsSection {
        guard showsPageDivider else { return nil }
        let view = outlineView.makeView(
            withIdentifier: SidebarPageDividerCellView.identifier,
            owner: self) as? SidebarPageDividerCellView ?? SidebarPageDividerCellView()
        return view
    }
    let view = outlineView.makeView(
        withIdentifier: SidebarOutlineCellView.identifier,
        owner: self) as? SidebarOutlineCellView ?? SidebarOutlineCellView()
    view.configure(node: node, coordinator: self)
    return view
}
```

Replace `SidebarNewTabCellView` with the separator-only cell:

```swift
@MainActor
private final class SidebarPageDividerCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-page-divider-cell")
    static let height: CGFloat = 13

    private let divider = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        identifier = Self.identifier
        setup()
    }

    private func setup() {
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
```

Do not add hidden-state configuration, a target/action, or a coordinator reference to this cell. The coordinator returns no cell when the divider is absent.

- [ ] **Step 5: Remove obsolete button artifacts**

Delete the complete `newTabOpensGlobalSearchWithoutBecomingAPage` test extension. Remove the `新建页面` object from `Localizable.xcstrings`:

```json
"新建页面" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "New Tab"
      }
    },
    "zh-Hans" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "新建页面"
      }
    }
  }
}
```

Do not modify `TabCommands.swift`; its existing Command-T global search stays unchanged.

- [ ] **Step 6: Add the production-style divider geometry regression**

Make the test harness match the real outline styling immediately after creating its column:

```swift
outline.style = .sourceList
outline.floatsGroupRows = false
```

Change the layout-test call back to `try` and pass the complete harness:

```swift
let rendered = try renderedPageArea(in: harness)
```

Add these fields to `RenderedPageArea`:

```swift
let dividerIsGroupItem: Bool
let dividerOutlineCellVisible: Bool
let precedingRowGap: CGFloat
```

Change the helper signature and introduce its outline locally:

```swift
@MainActor
private func renderedPageArea(in harness: Harness) throws -> RenderedPageArea {
    let outline = harness.outline
```

After deriving `dividerRow`, `dividerView`, and `dividerRect`, identify the structural item:

```swift
let dividerItem = try #require(outline.item(atRow: dividerRow))
```

Add these values to the returned snapshot:

```swift
dividerIsGroupItem: harness.coordinator.outlineView(
    outline, isGroupItem: dividerItem),
dividerOutlineCellVisible: outline.delegate?.outlineView?(
    outline, shouldShowOutlineCellForItem: dividerItem) ?? true,
precedingRowGap: dividerRect.minY
    - outline.rect(ofRow: dividerRow - 1).maxY,
```

Assert the structural row has no group appearance, disclosure cell, or leading geometry in every approved state:

```swift
#expect(!rendered.dividerIsGroupItem, Comment(rawValue: item.name))
#expect(!rendered.dividerOutlineCellVisible, Comment(rawValue: item.name))
#expect(rendered.precedingRowGap == 0, Comment(rawValue: item.name))
```

The existing `temporaryRowOffset` assertion still verifies that a visible divider consumes exactly 13 points and a hidden row consumes zero visible geometry.

- [ ] **Step 7: Run the focused suite and verify the centering test is RED**

Run from `apple/`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter SidebarPageSectionTests --quiet \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected RED: `.tabs` is still a group item, the optional disclosure delegate defaults to visible, and source-list styling inserts a 13-point gap before the structural row. The original button-removal and empty-drop assertions continue to pass.

- [ ] **Step 8: Remove group-row appearance from `.tabs`**

Change `isGroupItem` so only visible section headers use AppKit's group styling:

```swift
func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    guard let node = item as? SidebarOutlineNode else { return false }
    if node.isTabsSection { return false }
    if case .section = node.kind { return true }
    return false
}
```

Hide only the structural `.tabs` disclosure cell; keep outline cells unchanged for every other expandable node:

```swift
func outlineView(_ outlineView: NSOutlineView,
                 shouldShowOutlineCellForItem item: Any) -> Bool {
    guard let node = item as? SidebarOutlineNode else { return true }
    return !node.isTabsSection
}
```

Re-run the Step 7 command. Expected GREEN: both tests in `SidebarPageSectionTests` pass with source-list styling, zero leading gap, no `.tabs` disclosure, and unchanged empty-section drop behavior.

- [ ] **Step 9: Record the global close-others removal baseline**

Run from the repository root:

```bash
rg -n "关闭其他页面|closeOtherTabs" \
  apple/Sources/Marple \
  apple/Tests/MarpleKitTests
```

Expected baseline: references exist only in `TabStripView.swift`, `SidebarTabOutlineView.swift`, `AppModel.swift`, `SidebarUndoTests.swift`, and `Localizable.xcstrings`.

- [ ] **Step 10: Delete both UI entries and their selector**

Delete this button from `TabStripView`:

```swift
Button("关闭其他页面") { Task { await model.closeOtherTabs(tab.id) } }
```

Delete this appended item from the sidebar `.tab` menu:

```swift
items.append(menuItem(String(localized: "关闭其他页面"),
                      action: #selector(closeOtherTabsFromMenu(_:)), node: node))
```

Delete the complete sidebar selector:

```swift
@objc private func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
    guard let node = sender.representedObject as? SidebarOutlineNode,
          case .tab(let id) = node.kind else { return }
    Task { await model.closeOtherTabs(id) }
}
```

Do not change the adjacent ordinary `关闭页面` entries or selectors.

- [ ] **Step 11: Delete the now-unreferenced close-others operation and artifacts**

Delete `AppModel.closeOtherTabs(_:)` completely:

```swift
/// Close every tab except `keep` and any pinned tabs.
func closeOtherTabs(_ keep: NavTab.ID) async {
    let toClose = Set(tabs.filter { $0.id != keep && !$0.pinned }.map(\.id))
    guard let sync = closeTabsNow(toClose, actionName: String(localized: "关闭其他页面"),
                                  selectAfterClose: keep) else { return }
    if sync.activeChanged {
        await syncToActiveLocation(from: sync.previousPinnedContext)
    }
}
```

Delete only `undoCloseOthersRestoresClosedActiveAndRedoKeepsRequestedPage` from `SidebarUndoTests`. Keep `undoCloseRestoresPlacementHistoryContextAndActiveTab`, `undoBatchCloseIsOneStepAndPreservesSurvivingHistory`, and all other undo coverage.

Delete the complete `关闭其他页面` localization object:

```json
"关闭其他页面" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Close Other Pages"
      }
    },
    "zh-Hans" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "关闭其他页面"
      }
    }
  }
}
```

Run the Step 9 `rg` command again. Expected: exit 1 with no output, proving the feature has no remaining source, test, or localization references.

- [ ] **Step 12: Run focused and adjacent tests and verify GREEN**

Run:

```bash
cd apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter SidebarPageSectionTests --quiet \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter NavigationContextTests --quiet \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter SidebarUndoTests --quiet \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: all three suites pass. The sidebar suite contains the source-list four-state layout test and the unchanged real single/batch empty-section drop test. The undo suite retains ordinary and explicit multi-selection close coverage and no longer contains the dedicated close-others test.

- [ ] **Step 13: Run the full suite**

```bash
cd apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --quiet \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: the complete suite passes. If the quiet SwiftPM testing helper exits with the already observed SIGPIPE, rerun the identical command once. If that identical rerun also SIGPIPEs without an assertion failure, run the same command once more without `--quiet`; only a clean full-suite run permits completion.

- [ ] **Step 14: Build and launch the development app**

```bash
cd apple
make run
```

Expected: the debug bundle builds and opens from the cache-backed path. It does not replace the signed `/Applications/Marple.app`.

Manually verify the four approved states:

1. empty: `页面` only, with no gap;
2. temporary only: `页面` followed directly by temporary rows;
3. fixed only: `页面` followed directly by fixed rows;
4. both: `页面`, fixed rows, a vertically centered divider, then temporary rows.

Confirm there is no New Tab button, second visible section title, or disclosure arrow; right-click a page and confirm `关闭其他页面` is absent while `关闭页面` remains. Confirm empty fixed-area single/batch drops still work.

- [ ] **Step 15: Inspect and commit the surgical follow-up**

```bash
git diff --check
git status --short --branch
git diff --stat
git add \
  apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift \
  apple/Sources/Marple/Tabs/TabStripView.swift \
  apple/Sources/Marple/App/AppModel.swift \
  apple/Sources/Marple/Resources/Localizable.xcstrings \
  apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift \
  apple/Tests/MarpleKitTests/SidebarUndoTests.swift
git commit -m "fix: center sidebar divider and simplify tab closing"
```

Expected: exactly the six planned follow-up files are committed. Do not push until the user has tested the development app and asks for it.
