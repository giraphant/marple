# Sidebar Interaction Hotfixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add batch sharing and stateful folder icons while repairing incompatible page list contexts and preventing passive sidebar scroll jumps.

**Architecture:** Reuse the existing manifest renderer with several `TabNode` roots, derive the group symbol from `TabGroup.isCollapsed`, normalize only mismatched `.type` contexts at location creation and activation, and gate outline scrolling on a stable selection payload change. Keep every change inside the existing AppModel and AppKit coordinator boundaries.

**Tech Stack:** Swift 6, AppKit `NSOutlineView`/`NSMenu`, Swift Testing, Swift Package Manager.

## Global Constraints

- Work directly on `main`; do not create a branch or worktree.
- Do not change persisted schemas, workspace structure, pinning, grouping, fixed anchors, or Command-W withdrawal.
- Do not add batch pinning, batch rename, custom icon assets, or a generic menu capability abstraction.
- Preserve correct list contexts; repair only a `.type` pane whose type differs from the open entry.
- Use tests against real AppModel and AppKit coordinators; do not assert source text or mocks.

---

## File Map

- Modify `apple/Sources/Marple/App/AppModel.swift`: multi-root manifests and compatible type-list locations.
- Modify `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`: batch share menu, two-state group symbol, and reveal gating.
- Modify `apple/Tests/MarpleKitTests/NavigationContextTests.swift`: list-context regression coverage.
- Modify `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`: real outline menu/icon/viewport coverage.

---

### Task 1: Repair Incompatible Page List Contexts

**Files:**
- Modify: `apple/Tests/MarpleKitTests/NavigationContextTests.swift`
- Modify: `apple/Sources/Marple/App/AppModel.swift`

**Interfaces:**
- Consumes: `Entry.type`, `NavLocation.pane`, `NavLocation.listContext`, and `currentBrowseListContext`.
- Produces: temporary-page locations whose `.type` pane matches their open entry.

- [ ] **Step 1: Write failing activation and cross-type navigation tests**

Add one persisted-state test with a paper path stored under `.type(.chapter)`
and a non-nil list context. After `selectTab`, assert the pane is `.type(.paper)`,
the paper is visible, search/filters are empty, the previous sorts remain, and
the repaired location is stored on the tab. Add a second test that follows a
link from a book to a paper inside a temporary tab and asserts the new location
uses the paper list.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd apple && swift test --filter NavigationContextTests
```

Expected: the new tests fail because a non-nil mismatched context is trusted and
`sourceLocation(for:)` copies the source pane.

- [ ] **Step 3: Implement the minimal compatibility rule**

Resolve the target entry type from live entries, then `cachedType`. When a
temporary location has `.type(let stored)` and `stored != target`, replace it
with `.type(target)` plus:

```swift
ListContext(searchText: "", filters: [], filterMatch: .all,
            sorts: existingSorts)
```

Apply this while constructing a new source location and before restoring an
active temporary list. Leave non-type panes and matching contexts untouched.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the same filtered command and require zero failures.

---

### Task 2: Add Multi-Selection Share Manifest

**Files:**
- Modify: `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`
- Modify: `apple/Sources/Marple/App/AppModel.swift`
- Modify: `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`

**Interfaces:**
- Produces: `AppModel.shareManifest(for roots: [TabNode]) -> String?`.
- Consumes: selected sidebar tab/group nodes in visual order.

- [ ] **Step 1: Write a failing real-menu test**

Build two tabs plus a group in the existing AppKit harness, select a tab and a
group, call `menuNeedsUpdate`, and assert the menu contains
`复制分享清单`. Invoke the item and assert the general pasteboard contains one
manifest with the selected tab followed by the recursive group.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
cd apple && swift test --filter SidebarPageSectionTests
```

Expected: no batch share item exists.

- [ ] **Step 3: Generalize and wire the existing renderer**

Add the multi-root AppModel method, make existing single-root helpers delegate
to it, and add the batch menu item before the current group/close actions. Reuse
the current copy selector and toast; do not add a second rendering path.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same filtered command and require zero failures.

---

### Task 3: Render Collapsed and Expanded Group Icons

**Files:**
- Modify: `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`
- Modify: `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`

- [ ] **Step 1: Write a failing rendered-icon test**

Render a real group row, capture its `NSImageView.image`, toggle the group's
collapsed state, reload, and assert the rendered image changes. This catches a
hard-coded symbol without exposing private view types.

- [ ] **Step 2: Run the focused test and verify RED**

Run `cd apple && swift test --filter SidebarPageSectionTests`; expect both states
to render the same `folder` symbol.

- [ ] **Step 3: Derive the native symbol from model state**

Use `folder` when `group.isCollapsed` and `folder.fill` otherwise at outline-node
construction. Add no custom asset or state.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same filtered command and require zero failures.

---

### Task 4: Keep the Sidebar Viewport Stable on Passive Reloads

**Files:**
- Modify: `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`
- Modify: `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`

- [ ] **Step 1: Write a failing scroll-intent test**

Place enough tabs in a real `NSScrollView` to overflow, activate the final tab,
manually scroll to the top, and call coordinator reload without changing the
active target. Assert the clip origin remains at the top. Then activate a
different off-screen tab and assert reload reveals it.

- [ ] **Step 2: Run the focused test and verify RED**

Run `cd apple && swift test --filter SidebarPageSectionTests`; expect the passive
reload assertion to fail because `selectCurrentItem` always scrolls the active
row into view.

- [ ] **Step 3: Gate reveal on stable payload change**

Track the last synchronized target payload in the coordinator. Always maintain
selection, but call `scrollRowIntoViewIfOffscreen` only when that payload changes.
Apply the same gate to the multi-selection branch.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same filtered command and require zero failures.

---

### Task 5: Full Verification and Manual Build

- [ ] **Step 1: Run formatting and focused suites**

```bash
git diff --check
cd apple && swift test --filter NavigationContextTests
cd apple && swift test --filter SidebarPageSectionTests
```

- [ ] **Step 2: Run the full package test suite**

```bash
cd apple && swift test
```

Require all suites to pass with zero failures.

- [ ] **Step 3: Build and launch the debug app**

```bash
cd apple && make run
```

Verify the launched bundle is the fresh debug build, then hand off the four
interactions for manual checking.

- [ ] **Step 4: Commit the implementation**

```bash
git add apple/Sources/Marple/App/AppModel.swift \
  apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift \
  apple/Tests/MarpleKitTests/NavigationContextTests.swift \
  apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift
git commit -m "fix: stabilize sidebar page interactions"
```
