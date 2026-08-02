# Sidebar Hotfix and Undo Design

Date: 2026-08-02

## Goal

Repair the fixed/temporary page split introduced by `9f0d338` and make sidebar
structure edits participate in native macOS undo and redo. The work stays on
`main` and is limited to the five reported behaviours.

## Behaviour

### 1. Empty fixed-pages section accepts drops

`固定页面` is a container even when it currently has no children. AppKit must be
told that the section can contain children instead of deriving that capability
from `children.isEmpty`. A single temporary page or an ordered multi-selection
can be dropped into the empty section. The drop pins the pages and preserves
their visual order.

This follows the container-capability pattern used by NetNewsWire's outline
data source: whether a node can have children is independent of its current
child count.

### 2. Fixed rows do not repeat the pin icon

Membership in the `固定页面` section is the visual indication that a page is
fixed. Page and group rows in that section no longer show a trailing pin icon.
The icon is display-only today, so removing it does not remove an action.

Users can still unpin a page through its context menu or by dragging it into
the `页面` section.

### 3. Temporary pages restore their complete list context

Each temporary page owns the list context from which it was opened:

- pane or object type;
- search text;
- filter clauses and all/any matching mode;
- sort clauses.

Selecting a temporary page restores that context before synchronising the
middle list. The existing list selection then selects and scrolls to the open
entry. Changing search, filters, or sorting while a temporary page is active
updates that page's current navigation location, so returning to it restores
the latest state rather than only the state at creation time.

A command-palette result has no originating object list. Opening one therefore
switches the middle column immediately to a clean list for the entry's real
type, selects and reveals the entry, and saves that generated context on the
new temporary page. Opening from an object list continues to preserve that
list's search, filters, matching mode, and sorting instead.

Pinned pages remain different: they share the aggregate pinned-pages list.
Changes made in that shared list do not overwrite a page's saved object-list
context. Unpinning a page restores its saved context.

For a named saved view, the saved-view identity remains authoritative; restoring
a tab does not roll the shared saved-view definition back to an older version.
The design does not preserve arbitrary pixel scroll offsets or list/grid display
mode. It restores the semantic list context and reveals the open entry.

`NavLocation` stores one optional `ListContext` value containing search, filter,
matching, and sort state. This keeps the navigation model cohesive instead of
adding several parallel optional properties. State written before this change
continues to decode with a missing context. Its first activation reconstructs
and saves a clean object-type context for the open entry so the list can reveal
it instead of inheriting unrelated global browse settings. A valid saved-view
location keeps its saved-view identity and current shared definition.

### 4. A temporary multi-selection can create a group

The context menu offers `把这 N 个合成一个新组` for every pure page selection of
two or more rows, including temporary pages and a mixed fixed/temporary
selection. One high-level model intent performs the action synchronously:

1. pin every selected page;
2. group the pages in visual order using the existing group-creation policy;
3. show the new group in `固定页面`.

Selections containing a group keep the existing mixed-selection rules; this
change does not invent new grouping semantics for group-plus-page selections.

### 5. Native undo and redo for sidebar structure

The main window supplies a session-scoped `UndoManager`. Standard macOS menu
routing provides `Command-Z` for undo and `Shift-Command-Z` for redo, including
localized action names.

One user gesture creates one undo transaction, even when the implementation
performs several mutations. This applies to:

- pinning and unpinning;
- drag moves, reordering, and grouping;
- creating and renaming page groups;
- renaming pages;
- closing one page, closing other pages, and batch closing;
- object-type ordering and visibility;
- saved-view ordering, renaming, and deletion.

Undoing a close restores every closed page at its exact former position, with
its group membership, pinned state, navigation history, and list context. If
the active page was closed, undo reactivates it. A batch close is restored by
one undo, and redo closes the same batch again.

Undo state is scoped to sidebar-owned fields. Applying an undo preserves later
navigation history on pages that never closed; a restored closed page uses the
history captured when it closed. This prevents undoing a sidebar reorder from
silently rewinding unrelated reading navigation.

The following do not enter this undo stack:

- selection, opening a page, scrolling, or ordinary navigation;
- expanding or collapsing sections and groups;
- Space deletion or other Space-management commands;
- vault file creation, editing, trash, restore, or permanent deletion.

The undo stack is not persisted across launches and is cleared when the model
is replaced with a different vault/workspace.

## Architecture

`NavLocation` gains one optional `ListContext` containing search text, filters,
matching mode, and sorting. `AppModel` has one path for capturing the effective
temporary-page context and one path for applying it. Existing browse and pinned
shared contexts remain separate.

The window delegate exposes one `UndoManager`. Each high-level user intent owns
its undo registration and captures only the old value it changes. Its undo
handler captures the current value before applying the old one, then registers
that inverse; this is sufficient for redo and needs no custom history stack.

Page moves, pinning, grouping, and renaming save only the affected workspace
topology, pin values, or names. Cross-Space moves save the structural state of
the two affected workspaces. Type and saved-view edits save their old arrays.
There is no generic before/after transaction object, nested-transaction counter,
or universal workspace merge algorithm.

Closing is the one operation that needs a dedicated record: the removed
`NavTab` values, the former root topology, and the formerly active tab ID.
Restoration keeps the current history of tabs that never closed and reinserts
the captured closed tabs with their own history and list context. This narrowly
implements exact close restoration without making every sidebar operation use
a defensive merge layer.

## Verification

Automated model tests must demonstrate red before implementation and green after
it for:

1. switching temporary pages restores pane and `ListContext`, while a saved
   view continues to use its latest shared definition;
2. grouping temporary and mixed fixed/temporary selections pins the pages,
   preserves visual order, creates one fixed group, and consumes one undo step;
3. undo and redo restore/reapply representative pin, move, group, and rename
   mutations;
4. undoing single and batch closes restores exact placement, group membership,
   active selection, history, and list context while preserving the later
   histories of tabs that never closed;
5. type and saved-view configuration edits restore their previous values;
6. legacy persisted navigation locations still decode.

Private AppKit view hierarchy, drag hit-testing, and menu wiring are not exposed
or abstracted solely for tests. After the focused tests and complete Swift test
suite pass, build and ad-hoc-sign the development app, then manually verify:

- single and batch drops into an empty fixed-pages section;
- the absence of trailing pin icons;
- the temporary-page group command appearing and moving the new group above;
- list restoration selecting and revealing the open entry;
- standard undo/redo menu routing and shortcuts;
- expand/collapse creating no undo entry.
