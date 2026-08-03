# Unified Sidebar Page Sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render fixed and temporary pages as one visual `页面` area, with one Arc-style `＋ 新建页面` action that opens the existing Command-T global search.

**Architecture:** Keep the existing `.pinned` and `.tabs` outline sections and every model/drag/undo route unchanged. Rename only the visible `.pinned` heading to `页面`, then give the existing `.tabs` section a dedicated AppKit cell that renders an optional native separator and an unselected New Tab button before the section's existing temporary children. The `.tabs` section itself remains the outline item, so no synthetic node, selection state, pasteboard payload, or persistence schema is introduced.

**Tech Stack:** Swift 6, AppKit `NSOutlineView`/`NSBox`/`NSButton`, Swift Testing, Swift Package Manager, existing `CommandPalettePresenter`.

## Global Constraints

- Work directly on `main`; do not create a branch or worktree.
- Keep `.pinned` and `.tabs` as separate root sections with their existing stable keys, expansion state, children, and drag/drop routing.
- Do not change `Workspace`, `NavTab`, `PersistedState`, undo/redo, pinning, grouping, ordering, page activation, or fixed-anchor behavior.
- Do not add a synthetic New Tab outline node. The action is presentation owned by the existing `.tabs` section header.
- New Tab must call `CommandPalettePresenter.toggle(model:)`; it must not call `AppModel.newTab()` or create a note/page.
- The separator is shown exactly when temporary pages exist. It does not depend on whether fixed pages exist.
- Do not add `Clear`, Peek, hover-close, a second visible section title, or new defensive fallbacks.
- Use a native `NSBox` separator, matching the established AppKit pattern checked in CotEditor and NetNewsWire under `/tmp/marple-reference-repos`.
- Preserve unrelated working-tree content. Do not push, publish, install over `/Applications/Marple.app`, or create a release as part of this plan.

---

## File Map

- Modify `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`: rename the visible fixed-page heading, special-case the `.tabs` section row, and add its small dedicated cell.
- Modify `apple/Sources/Marple/Resources/Localizable.xcstrings`: add `新建页面` / `New Tab`.
- Create `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`: cover all four visual states, the Command-T route, non-selection/non-drag behavior, and the empty fixed-section drop target.

---

### Task 1: Specify the Four Layout States and Preserve Section Semantics

**Files:**
- Create: `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`

**Behavior under test:**
- no fixed/no temporary: `页面`, `新建页面`;
- no fixed/temporary: `页面`, divider, `新建页面`, temporary row;
- fixed/no temporary: `页面`, fixed row, `新建页面`;
- fixed/temporary: `页面`, fixed row, divider, `新建页面`, temporary row;
- the New Tab row is the existing `.tabs` section, so it is not selectable or draggable;
- the empty `.pinned` section remains expandable and validates both single and batch page drops.

- [ ] **Step 1: Add the AppKit test harness and four-state failing test**

Create `SidebarPageSectionTests.swift` with a real coordinator and outline view. Keep the harness in the test file; do not expose private production hierarchy for testing.

```swift
import AppKit
import Testing
@testable import Marple
@testable import MarpleKit

@Suite(.serialized)
struct SidebarPageSectionTests {
    private struct LayoutCase {
        let name: String
        let hasFixed: Bool
        let hasTemporary: Bool
        let expectedRows: [String]
    }

    @MainActor
    @Test func pageAreaRendersTheFourApprovedStates() async throws {
        let pageTitle = String(localized: "页面")
        let newTabTitle = String(localized: "新建页面")
        let cases = [
            LayoutCase(name: "empty", hasFixed: false, hasTemporary: false,
                       expectedRows: [pageTitle, newTabTitle]),
            LayoutCase(name: "temporary-only", hasFixed: false, hasTemporary: true,
                       expectedRows: [pageTitle, newTabTitle, "Temporary"]),
            LayoutCase(name: "fixed-only", hasFixed: true, hasTemporary: false,
                       expectedRows: [pageTitle, "Fixed", newTabTitle]),
            LayoutCase(name: "both", hasFixed: true, hasTemporary: true,
                       expectedRows: [pageTitle, "Fixed", newTabTitle, "Temporary"]),
        ]

        for item in cases {
            let harness = try await makeHarness(
                hasFixed: item.hasFixed,
                hasTemporary: item.hasTemporary)
            let rendered = try renderedPageArea(in: harness.outline)

            #expect(rendered.rows == item.expectedRows,
                    Comment(rawValue: item.name))
            #expect(rendered.dividerVisible == item.hasTemporary,
                    Comment(rawValue: item.name))
            #expect(rendered.newTabButton.title == newTabTitle,
                    Comment(rawValue: item.name))
        }
    }
}
```

Add the following test-only harness and recursive view inspection helpers in the same file:

```swift
extension SidebarPageSectionTests {
    @MainActor
    private struct Harness {
        let model: AppModel
        let coordinator: SidebarOutlineView.Coordinator
        let outline: NSOutlineView
    }

    @MainActor
    private struct RenderedPageArea {
        let rows: [String]
        let dividerVisible: Bool
        let newTabButton: NSButton
        let newTabRow: Int
    }

    @MainActor
    private func makeHarness(hasFixed: Bool, hasTemporary: Bool) async throws -> Harness {
        let fixed = entry(path: "books/fixed.md", title: "Fixed")
        let temporary = entry(path: "books/temporary.md", title: "Temporary")
        let model = AppModel(client: StubVaultClient(
            entries: [fixed, temporary],
            texts: [fixed.path: "# Fixed", temporary.path: "# Temporary"]))
        await model.loadIndex()

        if hasFixed {
            await model.open(fixed.path)
            model.togglePin(try #require(model.activeTabID))
        }
        if hasTemporary {
            await model.openInNewTab(temporary.path)
        }

        let collapseKey = "marple.collapsedSidebarSections"
        let defaults = UserDefaults.standard
        let previousCollapsedSections = defaults.object(forKey: collapseKey)
        defaults.set([], forKey: collapseKey)
        defer {
            if let previousCollapsedSections {
                defaults.set(previousCollapsedSections, forKey: collapseKey)
            } else {
                defaults.removeObject(forKey: collapseKey)
            }
        }

        let coordinator = SidebarOutlineView.Coordinator(model: model)
        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.width = 280
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outlineView = outline
        coordinator.reload(outline)
        outline.layoutSubtreeIfNeeded()
        return Harness(model: model, coordinator: coordinator, outline: outline)
    }

    @MainActor
    private func renderedPageArea(in outline: NSOutlineView) throws -> RenderedPageArea {
        let pageTitle = String(localized: "页面")
        let newTabTitle = String(localized: "新建页面")
        var rows: [String] = []
        var button: NSButton?
        var buttonRow = -1
        var dividerVisible = false

        for row in 0..<outline.numberOfRows {
            guard let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            let text = descendants(of: NSTextField.self, in: view).map(\.stringValue)
            if text.contains(pageTitle) { rows.append(pageTitle) }
            if text.contains("Fixed") { rows.append("Fixed") }
            if text.contains("Temporary") { rows.append("Temporary") }
            if let newTab = descendants(of: NSButton.self, in: view)
                .first(where: { $0.title == newTabTitle }) {
                rows.append(newTabTitle)
                button = newTab
                buttonRow = row
                dividerVisible = descendants(of: NSBox.self, in: view)
                    .contains(where: { $0.boxType == .separator && !$0.isHidden })
            }
        }

        return RenderedPageArea(
            rows: rows,
            dividerVisible: dividerVisible,
            newTabButton: try #require(button),
            newTabRow: try #require(buttonRow >= 0 ? buttonRow : nil))
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var result = view.subviews.compactMap { $0 as? T }
        for child in view.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }

    private func entry(path: String, title: String) -> Entry {
        Entry(path: path, type: .book, title: title, author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }
}
```

- [ ] **Step 2: Add failing New Tab action/outline-semantics coverage**

Add this test. It verifies the button opens the same `CommandPalettePanel` as Command-T, creates no `NavTab`, does not become selected, and inherits the existing section's nil pasteboard payload.

```swift
extension SidebarPageSectionTests {
    @MainActor
    @Test func newTabOpensGlobalSearchWithoutBecomingAPage() async throws {
        NSApp.windows.compactMap { $0 as? CommandPalettePanel }.forEach { $0.close() }
        defer { NSApp.windows.compactMap { $0 as? CommandPalettePanel }.forEach { $0.close() } }

        let harness = try await makeHarness(hasFixed: false, hasTemporary: false)
        let rendered = try renderedPageArea(in: harness.outline)
        let item = try #require(harness.outline.item(atRow: rendered.newTabRow))

        #expect(!harness.coordinator.outlineView(harness.outline, shouldSelectItem: item))
        #expect(harness.coordinator.outlineView(
            harness.outline, pasteboardWriterForItem: item) == nil)
        #expect(harness.outline.selectedRowIndexes.isEmpty)

        rendered.newTabButton.performClick(nil)

        #expect(NSApp.windows.contains { $0 is CommandPalettePanel && $0.isVisible })
        #expect(harness.model.tabs.isEmpty)
        #expect(harness.outline.selectedRowIndexes.isEmpty)
    }
}
```

- [ ] **Step 3: Add the empty fixed-section drag regression**

Add a minimal `NSDraggingInfo` test double at file scope. This is test-only plumbing around AppKit's protocol, not a production abstraction.

```swift
@MainActor
private final class SidebarDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    init(payloads: [String]) {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("marple-sidebar-page-section-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let items = payloads.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(payload, forType: SidebarDragPasteboard.tabItem)
            return item
        }
        pasteboard.writeObjects(items)
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination destination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
```

Locate the actual empty `.pinned` section by its unique invariant: among the two possible localized labels during the RED/GREEN transition (`固定页面` before the change, `页面` after it), it is the one that remains expandable with no children. Then validate and accept real single and batch browse-card drops:

```swift
extension SidebarPageSectionTests {
    @MainActor
    @Test func emptyFixedSectionStillAcceptsSingleAndBatchPageDrops() async throws {
        let single = try await makeHarness(hasFixed: false, hasTemporary: false)
        let singleSection = try #require(emptyPinnedSection(in: single))
        let singleDrag = SidebarDraggingInfo(payloads: ["entry:books/fixed.md"])
        #expect(single.coordinator.outlineView(
            single.outline, validateDrop: singleDrag,
            proposedItem: singleSection, proposedChildIndex: 0) == .move)
        #expect(single.coordinator.outlineView(
            single.outline, acceptDrop: singleDrag,
            item: singleSection, childIndex: 0))
        await waitForPinnedPaths(["books/fixed.md"], in: single.model)
        #expect(pinnedPaths(in: single.model) == ["books/fixed.md"])

        let batch = try await makeHarness(hasFixed: false, hasTemporary: false)
        let batchSection = try #require(emptyPinnedSection(in: batch))
        let batchDrag = SidebarDraggingInfo(payloads: [
            "entry:books/fixed.md", "entry:books/temporary.md"
        ])
        #expect(batch.coordinator.outlineView(
            batch.outline, validateDrop: batchDrag,
            proposedItem: batchSection, proposedChildIndex: 0) == .move)
        #expect(batch.coordinator.outlineView(
            batch.outline, acceptDrop: batchDrag,
            item: batchSection, childIndex: 0))
        await waitForPinnedPaths(
            ["books/fixed.md", "books/temporary.md"], in: batch.model)
        #expect(pinnedPaths(in: batch.model) == [
            "books/fixed.md", "books/temporary.md"
        ])
    }

    @MainActor
    private func emptyPinnedSection(in harness: Harness) -> Any? {
        let possibleTitles = Set([
            String(localized: "固定页面"), String(localized: "页面")
        ])
        for row in 0..<harness.outline.numberOfRows {
            guard let item = harness.outline.item(atRow: row),
                  harness.coordinator.outlineView(
                    harness.outline, isItemExpandable: item),
                  let view = harness.outline.view(
                    atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            let titles = descendants(of: NSTextField.self, in: view).map(\.stringValue)
            if !possibleTitles.isDisjoint(with: titles) { return item }
        }
        return nil
    }

    @MainActor
    private func pinnedPaths(in model: AppModel) -> [String] {
        model.tabs
            .filter(\.pinned)
            .compactMap { $0.identityLocation.openPath }
    }

    @MainActor
    private func waitForPinnedPaths(_ paths: [String], in model: AppModel) async {
        for _ in 0..<50 {
            if pinnedPaths(in: model) == paths { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
```

- [ ] **Step 4: Run the focused suite and verify RED**

Run from `apple/`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter SidebarPageSectionTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected RED: `pageAreaRendersTheFourApprovedStates` cannot find `新建页面` and still sees `固定页面`; `newTabOpensGlobalSearchWithoutBecomingAPage` also cannot find its button. The empty fixed-section test should already validate and accept both drops, then observe one and two pinned paths in source order, proving the baseline behavior the rendering change must preserve.

Do not commit failing tests.

---

### Task 2: Render the Existing Tabs Section as Divider Plus New Tab

**Files:**
- Modify: `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift:13-26, 686-708, 1827-1986`
- Modify: `apple/Sources/Marple/Resources/Localizable.xcstrings`
- Test: `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`

**Interfaces:**
- Keeps: `SidebarOutlineNode.Kind.section(.pinned/.tabs)` and their current children/payload behavior.
- Adds: private `SidebarNewTabCellView` in the existing sidebar source file.
- Consumes: existing `CommandPalettePresenter.toggle(model:)`.

- [ ] **Step 1: Give the fixed section the single visible Page heading**

Change only the localized presentation title for `.pinned`; retain `.tabs`' internal title for its existing drag diagnostics even though its custom cell does not render it. Section identity, expansion, and routing continue to use the enum case and stable key, not this text.

```swift
var title: String {
    switch self {
    case .objects: return String(localized: "物件")
    case .views:   return String(localized: "视图")
    case .pinned:  return String(localized: "页面")
    case .tabs:    return String(localized: "页面")
    }
}
```

Do not merge or conditionally omit either section in `makeRootItems()`.

- [ ] **Step 2: Special-case only the `.tabs` section's row height and view**

Update the two delegate methods without changing selection, expansion, or drag methods:

```swift
func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    guard let node = item as? SidebarOutlineNode else { return 30 }
    switch node.kind {
    case .section(.tabs):
        return SidebarNewTabCellView.height(showsDivider: !node.children.isEmpty)
    case .section:
        return 22
    case .pane, .tab, .group:
        return 30
    }
}

func outlineView(_ outlineView: NSOutlineView,
                 viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let node = item as? SidebarOutlineNode else { return nil }
    if node.isTabsSection {
        let view = outlineView.makeView(
            withIdentifier: SidebarNewTabCellView.identifier,
            owner: self) as? SidebarNewTabCellView ?? SidebarNewTabCellView()
        view.configure(showsDivider: !node.children.isEmpty, coordinator: self)
        return view
    }
    let view = outlineView.makeView(
        withIdentifier: SidebarOutlineCellView.identifier,
        owner: self) as? SidebarOutlineCellView ?? SidebarOutlineCellView()
    view.configure(node: node, coordinator: self)
    return view
}
```

The divider condition deliberately reads `node.children.isEmpty`; fixed-page count is irrelevant.

- [ ] **Step 3: Add the small dedicated AppKit cell**

Insert this beside `SidebarOutlineCellView` in the same file:

```swift
@MainActor
private final class SidebarNewTabCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-new-tab-cell")

    private let divider = NSBox()
    private let button = NSButton()
    private weak var coordinator: SidebarOutlineView.Coordinator?

    static func height(showsDivider: Bool) -> CGFloat {
        showsDivider ? 46 : 30
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

    func configure(showsDivider: Bool,
                   coordinator: SidebarOutlineView.Coordinator) {
        self.coordinator = coordinator
        divider.isHidden = !showsDivider
    }

    private func setup() {
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        button.title = String(localized: "新建页面")
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.bezelStyle = .inline
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(openNewTab(_:))
        button.translatesAutoresizingMaskIntoConstraints = false

        addSubview(divider)
        addSubview(button)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @objc private func openNewTab(_ sender: NSButton) {
        guard let coordinator else { return }
        CommandPalettePresenter.toggle(model: coordinator.model)
    }
}
```

- [ ] **Step 4: Add the one localization key**

Add the following catalog entry in sorted position in `Localizable.xcstrings`:

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

Do not rename the existing `固定页面` catalog key; it is still used by pin actions and context menus.

- [ ] **Step 5: Run the focused suite and verify GREEN**

Run:

```bash
cd apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter SidebarPageSectionTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: all new tests pass. In particular, the four row sequences contain one visible `页面`, the separator appears only with temporary children, clicking New Tab opens a `CommandPalettePanel` without creating a tab, and both empty-section drag validations return `.move`.

- [ ] **Step 6: Commit the passing feature**

```bash
git add \
  apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift \
  apple/Sources/Marple/Resources/Localizable.xcstrings \
  apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift
git commit -m "feat: unify sidebar page sections"
```

---

### Task 3: Regression and Visual Verification

**Files:**
- Verify only; no planned production edits.

- [ ] **Step 1: Run adjacent navigation and undo suites**

```bash
cd apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter NavigationContextTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test --filter SidebarUndoTests \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: both suites pass unchanged, covering temporary-page scene restoration, fixed anchors/Command-W, page close, and sidebar undo/redo.

- [ ] **Step 2: Run the complete test suite**

```bash
cd apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/marple-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/marple-swiftpm-cache \
xcrun swift test \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks
```

Expected: every test passes. A transient SwiftPM helper/SIGPIPE is infrastructure noise only if an immediate isolated rerun passes without code changes; report both runs rather than hiding the first result.

- [ ] **Step 3: Build and launch the development app**

```bash
cd apple
make run
```

This builds and opens the cache-backed development bundle. It does not replace the signed `/Applications/Marple.app` or change that bundle's cache identity.

- [ ] **Step 4: Manually inspect the four real sidebar states**

In both light and dark appearance, verify:

1. no pages: one `页面` heading, then `＋ 新建页面`;
2. one temporary page: one heading, divider, New Tab, temporary row;
3. one fixed page only: one heading, fixed row, New Tab, no divider;
4. both kinds: heading, fixed rows, divider, New Tab, temporary rows.

Also confirm:

- New Tab aligns with ordinary page icons/text and opens global search;
- the action itself never highlights like a page row;
- fixed and temporary page selection, right-click menus, multi-selection, grouping, and drag/drop still work;
- dropping one and multiple browse cards into an empty fixed area still produces fixed pages;
- there is no second visible heading and no `Clear` action.

If spacing alone needs adjustment, change only the three constants in `SidebarNewTabCellView` (`46`, `7`, `22`), rerun the focused suite, and amend the feature commit. Do not refactor the outline model for visual tuning.

- [ ] **Step 5: Inspect the final diff and repository state**

```bash
git status --short --branch
git diff HEAD^ --check
git diff HEAD^ --stat
```

Expected: `main` contains one feature commit after the plan/spec documentation, whitespace checks are clean, and the feature commit touches only the three files in Task 2. Do not push until the user has tested and asks for it.
