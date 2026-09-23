# Sidebar Create Menu and Antigravity Design

## Goal

Turn the sidebar footer `+` into one native creation menu and add Antigravity
as a first-class interactive Reader AI agent, while keeping both changes inside
the existing sidebar and AI-dispatch architecture.

## Native Creation Menu

The existing footer `+` stops calling `addSpace()` directly and becomes a
standard macOS `Menu`. It keeps the same plain 28-point button footprint and
hides the menu indicator. The menu contains only four creation actions:

1. `新建空间`
2. `新建文件夹`
3. a separator
4. `新建笔记` with the existing Command-N shortcut
5. `新建页面…` with the existing Command-T shortcut

`新建页面…` opens the existing global command palette; it does not create a
blank note. `新建笔记` continues through `newIdeaNote()`. `新建空间` continues
through `addSpace()`. No custom Arc-style popover, primary-action mode, recent
items, or additional creation types are introduced.

## First-Class Folders

Folders become durable nodes rather than wrappers that exist only while they
contain at least two pages. A folder remains present with one or zero children
and disappears only through an explicit `解散文件夹` action. Dissolving promotes
its children into the same parent position and never closes pages.

`Workspace` therefore supports a structurally non-empty state with zero tabs:

- `activeID` and `activeTab` become optional;
- an empty initializer creates zero tabs and zero root nodes;
- `createFolder()` appends an empty root folder and returns its ID;
- normalization prunes invalid/duplicate tab leaves but preserves folders of
  every size;
- closing the last page clears the active tab and enters browsing mode while
  retaining any folders;
- a workspace is discarded only when it has neither pages nor folder nodes.

The recursive `WorkspaceTreeSnapshot` already represents an empty group, so no
new persisted field or migration is needed. Restoration accepts a zero-tab tree
when it contains folders. Existing legacy state still restores as before.

The pinned projection keeps empty folder shells visible. Empty folders have no
disclosure chevron until they receive a child, but remain valid drag targets.
Moving or closing children no longer implicitly dissolves their ancestors.

`新建文件夹` creates `文件夹 N` at the current Space root, selects it, and starts
the existing inline rename interaction. The active Space may have no pages; in
that case `AppModel` creates an empty `Workspace` to own and persist the folder.
The rename request is transient presentation state and is cleared immediately
after the outline begins editing.

## Antigravity Reader AI Preset

The Reader AI agent picker gains `Antigravity (agy)`. Selecting it stores the
command:

```text
agy --prompt-interactive
```

The existing runner then launches the command from the vault root and supplies
the generated Marple prompt as its positional prompt. Antigravity stays
interactive after submitting that initial prompt. The existing PATH already
includes `~/.local/bin`, Antigravity's default macOS installation directory.

This is an agent preset, not a new dispatch target. Superset, Orca, Otty,
Terminal, and custom dispatch templates remain unchanged, as do the context
package, prompt boundaries, and logging. A missing or failing `agy` command uses
the existing launch/failure reporting path.

## Scope and Constraints

- Work directly on `main`; do not create a branch or worktree.
- Use the native SwiftUI/AppKit menu and existing inline rename machinery.
- Do not add a custom popover, placeholder page, schema version, generic action
  framework, AGY-specific runner branch, or speculative install detection.
- Preserve page contents, pinning, histories, list contexts, and folder order.
- Keep current Command-N and Command-T behavior as the single source of truth.

## Verification

Automated tests cover empty-folder creation, one/zero-child persistence,
explicit dissolution with child promotion, closing the last page without losing
folders, zero-tab snapshot round trips, and the Antigravity interactive command.
Existing navigation, sidebar page-section, persistence, drag/drop, Reader AI,
and undo suites must remain green. A signed debug app is then built and launched
for visual testing of the native menu and inline rename.
