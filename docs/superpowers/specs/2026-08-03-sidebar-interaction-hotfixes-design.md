# Sidebar Interaction Hotfixes Design

## Goal

Make four small sidebar interactions consistent without changing the workspace
schema or introducing a generic action framework:

1. a multi-selection can copy one share manifest;
2. a group icon visibly reflects its collapsed state;
3. a page whose stored object list cannot contain its document repairs itself;
4. passive sidebar refreshes do not pull a manually scrolled viewport back to
   the active page.

## Batch Share Manifest

The multi-selection menu gains `复制分享清单` before the existing group and close
actions. Selected tab and group rows become top-level `TabNode` roots in visual
order and go through the existing `TabShareNode` renderer once. Groups retain
their recursive hierarchy. Rename remains single-item only; batch pinning is
outside this change.

`AppModel` generalizes its existing single-tab and single-group manifest helpers
to accept several `TabNode` roots. The two existing helpers delegate to that
method, so Markdown formatting continues to have one implementation.

## Group Icon State

A collapsed group uses the native `folder` symbol and an expanded group uses
`folder.fill`. `TabGroup.isCollapsed` already owns the state, so the outline
node derives its symbol directly from that value. No custom asset, animation,
or additional UI state is introduced.

## Repairing an Incompatible List Context

The persisted state contains pages whose document type and stored type pane do
not match—for example, the book `Intention` and the paper `Autonomy and Personal
History` both carry a `.chapter` pane. Their non-nil `listContext` bypasses the
legacy nil-context migration, leaving the open path absent from the middle
list.

For a temporary page, a `.type(storedType)` pane is compatible only when it
matches the live entry type (falling back to `cachedType` during bootstrap).
On activation, an incompatible context is replaced with a clean list for the
entry's actual type: empty search, empty filters, `.all` matching, and the
existing sort order. Correct type contexts, saved views, theme panes, and fixed
pages keep their existing behavior.

The same rule applies when constructing a new navigation location. Following a
link or opening a different-type document inside a temporary page therefore
starts with that document's type list instead of copying an incompatible pane.
This prevents new bad state while the activation repair migrates existing tabs
when they are used.

## Stable Sidebar Viewport

The outline continues to synchronize its selected row on every reload, but it
scrolls that row into view only when the logical selection target changes. A
model refresh with the same active tab, pane, or collapsed ancestor updates
selection without changing the clip view origin. Selecting another tab or
Space still reveals the new target.

The coordinator tracks only the last stable payload (`tab`, `group`, or pane)
that it synchronized. This is presentation state, is not persisted, and does
not alter `AppModel` or `Workspace`.

## Scope

- Work directly on `main`; no branch or worktree.
- Do not change `PersistedState`, `NavTab`, `Workspace`, pinning, grouping,
  fixed anchors, or Command-W withdrawal.
- Do not add batch pinning, batch rename, custom folder assets, a generic menu
  capability layer, or speculative fallbacks.
- Keep current single-item menu wording and existing batch group/close actions.

## Verification

Automated tests cover the mixed tab/group menu and manifest, icon changes across
collapse/expand, repair and persistence of a mismatched type pane, prevention of
new cross-type mismatches, and sidebar scrolling on explicit selection versus
passive reload. Existing navigation, sidebar drag/drop, undo, and full package
tests must remain green. A debug app build is then installed and launched for
manual checking.
