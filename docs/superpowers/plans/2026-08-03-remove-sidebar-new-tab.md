# Remove Sidebar New Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the sidebar New Tab control while retaining one visible `页面` heading and a divider only when fixed and temporary page lists are both non-empty.

**Architecture:** Keep the existing `.pinned` and `.tabs` outline sections and all model behavior unchanged. Replace the current `.tabs` New Tab cell with a separator-only cell. Its hidden state is a visually collapsed 0.01-point row because AppKit rejects literal zero table-row heights; Command-T remains the sole global-search entry point.

**Tech Stack:** Swift 6, AppKit `NSOutlineView` and `NSBox`, Swift Testing, Swift Package Manager.

## Global Constraints

- Work directly on `main`; do not create a branch or worktree.
- Keep `.pinned` and `.tabs` as separate root sections with their existing stable keys, expansion state, children, and drag/drop routing.
- Keep the `.pinned` section's sole visible title as `页面`; never render the `.tabs` text title.
- Show the divider only when fixed and temporary pages are both present; otherwise the `.tabs` section header is visually collapsed to 0.01 point, the smallest practical positive height accepted by AppKit.
- Remove the sidebar New Tab button, its action, and its `新建页面` / `New Tab` localization. Do not change the existing Command-T command.
- Do not change `Workspace`, `NavTab`, `PersistedState`, undo/redo, pinning, grouping, ordering, page activation, or fixed-anchor behavior.
- Do not add `Clear`, Peek, hover-close, a synthetic outline node, new state, or defensive fallbacks.
- Preserve the empty `.pinned` section as an expandable single/batch drop target.
- Touch only the sidebar source, its focused test file, and the now-unused localization entry. Preserve unrelated content.
- Build and launch only the cache-backed development bundle; do not overwrite `/Applications/Marple.app`, sign, push, publish, or create a release.

---

## File Map

- Modify `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`: specify the button-free four states, remove the obsolete command-palette button test, and retain the real empty-section drop regression.
- Modify `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`: replace `SidebarNewTabCellView` with a separator-only `.tabs` section cell.
- Modify `apple/Sources/Marple/Resources/Localizable.xcstrings`: remove the now-unused `新建页面` key.

---

### Task 1: Remove the Sidebar New Tab Control

**Files:**
- Modify: `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`
- Modify: `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift:551-558, 686-711, 1827-1891`
- Modify: `apple/Sources/Marple/Resources/Localizable.xcstrings`

**Interfaces:**
- Keeps: `SidebarOutlineNode.Kind.section(.pinned/.tabs)` and both sections' existing children, selection, expansion, payload, and drop semantics.
- Produces: private `Coordinator.showsPageDivider: Bool`.
- Produces: private `SidebarPageDividerCellView` with `height(showsDivider:)` and `configure(showsDivider:)`.
- Removes: private `SidebarNewTabCellView` button/coordinator action and localization key `新建页面`.

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
#expect(rendered.newTabButtonCount == 0, Comment(rawValue: item.name))
if item.expectedDivider {
    #expect(rendered.dividerRowHeight == 13, Comment(rawValue: item.name))
} else {
    #expect(rendered.dividerRowHeight < 0.5, Comment(rawValue: item.name))
}
```

Change the rendered snapshot to keep only values relevant to the final UI:

```swift
@MainActor
private struct RenderedPageArea {
    let rows: [String]
    let dividerVisible: Bool
    let dividerRowHeight: CGFloat
    let newTabButtonCount: Int
}

@MainActor
private func renderedPageArea(in outline: NSOutlineView) throws -> RenderedPageArea {
    let pageTitle = String(localized: "页面")
    let newTabTitle = String(localized: "新建页面")
    var rows: [String] = []
    var dividerVisible = false
    var dividerRowHeight: CGFloat?
    var newTabButtonCount = 0

    for row in 0..<outline.numberOfRows {
        guard let view = outline.view(
            atColumn: 0, row: row, makeIfNecessary: true) else { continue }
        let text = descendants(of: NSTextField.self, in: view).map(\.stringValue)
        if text.contains(pageTitle) { rows.append(pageTitle) }
        if text.contains("Fixed") { rows.append("Fixed") }
        if text.contains("Temporary") { rows.append("Temporary") }
        let dividers = descendants(of: NSBox.self, in: view)
            .filter { $0.boxType == .separator }
        if !dividers.isEmpty {
            dividerVisible = dividers.contains { !$0.isHidden }
            dividerRowHeight = outline.rect(ofRow: row).height
        }
        newTabButtonCount += descendants(of: NSButton.self, in: view)
            .filter { $0.title == newTabTitle }.count
    }

    return RenderedPageArea(
        rows: rows,
        dividerVisible: dividerVisible,
        dividerRowHeight: try #require(dividerRowHeight),
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

Expected RED: `pageAreaRendersTheFourApprovedStates` reports the extra `新建页面` row/button in every case, an unexpected divider for `temporary-only`, and the old 30/46-point section-row height instead of the collapsed/13-point geometry. The existing New Tab action test still passes, proving the failure comes from the newly specified removal rather than broken test setup.

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
        return SidebarPageDividerCellView.height(showsDivider: showsPageDivider)
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
        let view = outlineView.makeView(
            withIdentifier: SidebarPageDividerCellView.identifier,
            owner: self) as? SidebarPageDividerCellView ?? SidebarPageDividerCellView()
        view.configure(showsDivider: showsPageDivider)
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

    private let divider = NSBox()

    static func height(showsDivider: Bool) -> CGFloat {
        // NSTableView rejects zero row heights; 0.01 pt is visually collapsed.
        showsDivider ? 13 : 0.01
    }

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

    func configure(showsDivider: Bool) {
        divider.isHidden = !showsDivider
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

Do not add a target/action or retain the coordinator in this cell.

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

- [ ] **Step 6: Run focused and adjacent tests and verify GREEN**

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

Expected: all three suites pass. The sidebar suite contains the four-state layout test and the unchanged real single/batch empty-section drop test; the obsolete New Tab action test no longer exists.

- [ ] **Step 7: Run the full suite**

```bash
cd apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --quiet \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: the complete suite passes. If the SwiftPM testing helper exits once with the already observed SIGPIPE, record that first result and immediately rerun the identical command without changing code; only a clean rerun permits completion.

- [ ] **Step 8: Build and launch the development app**

```bash
cd apple
make run
```

Expected: the debug bundle builds and opens from the cache-backed path. It does not replace the signed `/Applications/Marple.app`.

Manually verify the four approved states:

1. empty: `页面` only, with no gap;
2. temporary only: `页面` followed directly by temporary rows;
3. fixed only: `页面` followed directly by fixed rows;
4. both: `页面`, fixed rows, one divider, then temporary rows.

Confirm there is no New Tab button or second visible section title, and that empty fixed-area single/batch drops still work.

- [ ] **Step 9: Inspect and commit the surgical change**

```bash
git diff --check
git status --short --branch
git diff --stat
git add \
  apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift \
  apple/Sources/Marple/Resources/Localizable.xcstrings \
  apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift
git commit -m "fix: remove sidebar new tab action"
```

Expected: exactly the three planned files are committed. Do not push until the user has tested the development app and asks for it.
