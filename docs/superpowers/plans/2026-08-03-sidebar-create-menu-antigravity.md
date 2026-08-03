# Sidebar Create Menu and Antigravity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sidebar footer's single-purpose plus button with a native creation menu, make folders durable at zero or one child, and add an interactive Antigravity Reader AI preset.

**Architecture:** Keep creation UI in `SidebarView`, make `Workspace` capable of owning a folder forest without an active tab, and reuse the recursive tree snapshot for persistence. Represent AGY as one normal Reader AI agent preset whose command flows through the existing runner.

**Tech Stack:** Swift 6, SwiftUI `Menu`, AppKit `NSOutlineView`, Swift Testing, Swift Package Manager.

## Global Constraints

- Work directly on `main`; do not create a branch or worktree.
- Use the native menu and existing inline rename interaction; do not create a custom popover.
- Do not create placeholder pages or a new persistence schema version.
- Do not add an AGY-specific runner or dispatch-target branch.
- Preserve page contents, pinning, histories, list contexts, and forest order.
- Every production behavior follows a witnessed failing test.

---

## File Map

- Modify `apple/Sources/MarpleKit/Nav/Navigation.swift`: optional active selection, empty workspace, durable folders, explicit dissolution.
- Modify `apple/Sources/MarpleKit/Nav/PersistedState.swift`: restore zero-tab folder trees.
- Modify `apple/Sources/Marple/App/AppModel.swift`: retain folder-only workspaces, expose folder creation/dissolution, and adapt optional active selection.
- Modify `apple/Sources/Marple/Sidebar/SidebarView.swift`: native footer creation menu.
- Modify `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`: show empty folders, consume inline-rename requests, and expose dissolution in the group menu.
- Modify `apple/Sources/MarpleKit/Vault/ReaderAIAutomation.swift`: shared Reader AI agent presets.
- Modify `apple/Sources/Marple/Settings/SettingsView.swift`: render the shared presets including Antigravity.
- Modify `apple/Sources/Marple/Shared/AppPresentation.swift`: localized preset labels.
- Modify `apple/Tests/MarpleKitTests/NavigationTests.swift`: folder lifecycle and optional-selection coverage.
- Modify `apple/Tests/MarpleKitTests/PersistedStateTests.swift`: zero-tab folder snapshot coverage.
- Modify `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`: empty-folder rendering, rename request, and explicit dissolution coverage.
- Modify `apple/Tests/MarpleKitTests/ReaderAIAutomationTests.swift`: AGY command coverage.

---

### Task 1: Make Folders Durable Workspace Nodes

**Files:**
- Modify: `apple/Tests/MarpleKitTests/NavigationTests.swift`
- Modify: `apple/Tests/MarpleKitTests/PersistedStateTests.swift`
- Modify: `apple/Sources/MarpleKit/Nav/Navigation.swift`
- Modify: `apple/Sources/MarpleKit/Nav/PersistedState.swift`
- Modify: compile-required optional-selection call sites in `apple/Sources/Marple/App/AppModel.swift` and existing tests

**Interfaces:**
- Produces: `Workspace.init()`, `Workspace.createFolder() -> TabGroup.ID`, `Workspace.dissolveFolder(_ id: TabGroup.ID)`, `Workspace.activeID: NavTab.ID?`, and `Workspace.activeTab: NavTab?`.
- Preserves: `WorkspaceTreeSnapshot` wire format.

- [ ] **Step 1: Write failing folder-lifecycle tests**

Add tests whose hand-derived expectations cover these behaviors:

```swift
@Test func emptyFolderSurvivesZeroAndOneChild() throws {
    var workspace = Workspace()
    let folderID = workspace.createFolder()
    #expect(workspace.tabs.isEmpty)
    #expect(workspace.activeID == nil)
    #expect(workspace.group(folderID)?.children.isEmpty == true)
    #expect(!workspace.isEmpty)

    let pageID = workspace.newTab(a)
    workspace.moveTab(pageID, toGroup: folderID)
    #expect(workspace.group(folderID)?.tabIDs == [pageID])

    workspace.closeTab(pageID)
    #expect(workspace.activeID == nil)
    #expect(workspace.group(folderID)?.children.isEmpty == true)
    #expect(!workspace.isEmpty)
}

@Test func dissolvingFolderPromotesChildrenWithoutClosingThem() throws {
    var workspace = Workspace(initial: a)
    let firstID = try #require(workspace.activeID)
    let secondID = workspace.newTab(b)
    let folderID = workspace.createFolder()
    workspace.moveTabs([firstID, secondID], toGroup: folderID)

    workspace.dissolveFolder(folderID)

    #expect(workspace.group(folderID) == nil)
    #expect(workspace.tabs.map(\.id) == [firstID, secondID])
    #expect(workspace.rootNodes.compactMap(\.tabID) == [firstID, secondID])
}
```

Replace existing dissolution expectations with persistence expectations: moving
or closing a child leaves its folder in place. Update existing test reads of
`activeID`/`activeTab` with `#require` only where a page is guaranteed.

- [ ] **Step 2: Write a failing zero-tab persistence test**

Build a `PersistedWorkspaceSpace` with `tabs: []` and a tree containing one
empty group, pass it through `makeSpaces()`, and assert that its restored
workspace exists, has no active tab, retains the group name, and emits the same
empty-group tree snapshot.

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
cd apple && swift test --filter 'WorkspaceTests|NestedTabGroupTests|BatchTabActionsTests|PersistedStateTests' \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: compilation or assertions fail because an empty workspace/folder API
does not exist and normalization dissolves small groups.

- [ ] **Step 4: Implement the minimal workspace model**

Make the active selection optional, add the empty initializer and root-folder
methods, remove `dissolveSmall` from normalization, preserve root groups after
the last page closes, and define `isEmpty` as `tabs.isEmpty && root.isEmpty`.
`dissolveFolder` replaces the target group with its children at the same index.
Allow recursive-tree restoration with zero tabs when the tree has a group.
Update only compile-required active-selection call sites.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the same filtered command and require zero failures.

- [ ] **Step 6: Commit the model change**

```bash
git add apple/Sources/MarpleKit/Nav/Navigation.swift \
  apple/Sources/MarpleKit/Nav/PersistedState.swift \
  apple/Sources/Marple/App/AppModel.swift \
  apple/Tests/MarpleKitTests/NavigationTests.swift \
  apple/Tests/MarpleKitTests/PersistedStateTests.swift
git commit -m "feat: preserve empty sidebar folders"
```

---

### Task 2: Add the Native Sidebar Creation Menu

**Files:**
- Modify: `apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift`
- Modify: `apple/Sources/Marple/App/AppModel.swift`
- Modify: `apple/Sources/Marple/Sidebar/SidebarView.swift`
- Modify: `apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift`

**Interfaces:**
- Produces: `AppModel.createFolder()`, `AppModel.pendingFolderRenameID: TabGroup.ID?`, `AppModel.finishFolderRenameRequest(_ id: TabGroup.ID)`, and `AppModel.dissolveFolder(_ id: TabGroup.ID)`.
- Consumes: `Workspace.createFolder()`, `Workspace.dissolveFolder(_:)`, `CommandPalettePresenter.toggle(model:)`, `newIdeaNote()`, and `addSpace()`.

- [ ] **Step 1: Write failing real-model/outline tests**

Using the existing AppKit harness, start with a page-empty Space, call
`model.createFolder()`, reload the real outline, and assert `文件夹 1` is visible
under 页面 and the rename request is consumed when editing starts. Add a second
test that invokes the real group context-menu item `解散文件夹` and asserts that
the folder disappears while its pages remain in the same order.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd apple && swift test --filter SidebarPageSectionTests \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: the folder actions and rename request do not exist.

- [ ] **Step 3: Implement AppModel and outline folder lifecycle**

Create an empty workspace on demand, add a root folder, preserve it while
browsing, keep empty groups in `pinnedTabRootNodes`, begin inline editing after
reload, and add `解散文件夹` to the existing group menu. Do not add another
rename UI or close any descendant tabs.

- [ ] **Step 4: Replace the footer button with a native Menu**

Keep the current 28-point label and plain style. Add `新建空间`, `新建文件夹`, a
divider, `新建笔记` (Command-N), and `新建页面…` (Command-T). The final item calls
the existing command palette presenter; it must not call `newTab()`.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the same filtered command and require zero failures.

- [ ] **Step 6: Commit the UI change**

```bash
git add apple/Sources/Marple/App/AppModel.swift \
  apple/Sources/Marple/Sidebar/SidebarView.swift \
  apple/Sources/Marple/Sidebar/SidebarTabOutlineView.swift \
  apple/Tests/MarpleKitTests/SidebarPageSectionTests.swift
git commit -m "feat: add sidebar creation menu"
```

---

### Task 3: Add the Interactive Antigravity Preset

**Files:**
- Modify: `apple/Tests/MarpleKitTests/ReaderAIAutomationTests.swift`
- Modify: `apple/Sources/MarpleKit/Vault/ReaderAIAutomation.swift`
- Modify: `apple/Sources/Marple/Settings/SettingsView.swift`
- Modify: `apple/Sources/Marple/Shared/AppPresentation.swift`

**Interfaces:**
- Produces: `ReaderAIAgentPreset` with stable cases `claude`, `codex`, `antigravity`, and `custom`, plus `command: String?`; Antigravity's command is `agy --prompt-interactive`.
- Consumes: the unchanged `ReaderAIRunner.runScript(agent:vaultRoot:promptFilePath:)` path.

- [ ] **Step 1: Write a failing preset-to-launcher test**

Assert that the Antigravity preset resolves to `agy --prompt-interactive`, and
pass that command to the real run-script builder. Assert the launcher line is:

```text
exec agy --prompt-interactive "$marple_prompt"
```

This fails if the preset is missing, uses non-interactive `agy`, or loses the
initial Marple prompt.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
cd apple && swift test --filter ReaderAIAutomationTests \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Expected: `ReaderAIAgentPreset.antigravity` does not exist.

- [ ] **Step 3: Add and wire the shared preset**

Move the existing Claude/Codex/custom picker model into a shared
`ReaderAIAgentPreset`, add Antigravity, map its localized label in
`AppPresentation`, and keep the existing stored command key. Custom remains a
free-text command; no dispatch template or runner branch changes.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the same filtered command and require zero failures.

- [ ] **Step 5: Commit the AI preset**

```bash
git add apple/Sources/MarpleKit/Vault/ReaderAIAutomation.swift \
  apple/Sources/Marple/Settings/SettingsView.swift \
  apple/Sources/Marple/Shared/AppPresentation.swift \
  apple/Tests/MarpleKitTests/ReaderAIAutomationTests.swift
git commit -m "feat: add interactive antigravity preset"
```

---

### Task 4: Regression Verification and Test Build

- [ ] **Step 1: Check the final diff and formatting**

```bash
git diff --check
git status --short
```

- [ ] **Step 2: Run all affected suites together**

```bash
cd apple && swift test --filter 'WorkspaceTests|NestedTabGroupTests|BatchTabActionsTests|PersistedStateTests|SidebarPageSectionTests|NavigationContextTests|ReaderAIAutomationTests' \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Require zero failures.

- [ ] **Step 3: Run the full package test suite**

```bash
cd apple && swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Require zero failures.

- [ ] **Step 4: Build and restart the debug app**

```bash
cd apple && make build
osascript -e 'tell application "Marple" to quit'
open -n /Users/ramudai/Library/Caches/marple-dev/Marple.app
```

Verify the fresh process is running and report its build number.
