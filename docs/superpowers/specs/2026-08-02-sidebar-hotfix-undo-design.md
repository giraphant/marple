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

Pinned pages remain different: they share the aggregate pinned-pages list.
Changes made in that shared list do not overwrite a page's saved object-list
context. Unpinning a page restores its saved context.

For a named saved view, the saved-view identity remains authoritative; restoring
a tab does not roll the shared saved-view definition back to an older version.
The design does not preserve arbitrary pixel scroll offsets or list/grid display
mode. It restores the semantic list context and reveals the open entry.

Navigation-location persistence uses optional fields so state written before
this change continues to decode. Missing fields fall back to the current global
browse settings.

### 4. A temporary multi-selection can create a group

The context menu offers `把这 N 个合成一个新组` for every pure page selection of
two or more rows, including temporary pages and a mixed fixed/temporary
selection. The action is one transaction:

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

`NavLocation` regains per-location search state and adds optional filter and sort
state. `AppModel` has one path for capturing the effective temporary-page list
context and one path for applying it. Existing browse and pinned shared contexts
remain separate.

Sidebar mutations run through a small `AppModel` transaction boundary that
captures narrowly scoped before/after sidebar state and registers the inverse
with the window's `UndoManager`. Nested model calls within one gesture are
coalesced into the outer transaction. Restoring a transaction registers its
opposite, which gives native redo without a second custom stack.

Workspace structural snapshots contain topology, ordering, pin state, names,
and the payload needed to reinsert closed tabs. Restoration merges that
structure with still-open tabs so their later navigation histories are not
replaced. Object-type and saved-view edits snapshot only their respective
configuration.

## Verification

Automated regression tests must demonstrate red before implementation and green
after it for:

1. an empty fixed-pages section remains a valid container/drop destination;
2. fixed page and group rows have no trailing pin accessory;
3. switching temporary pages restores pane, search, filters, matching mode, and
   sort, after which the open entry is present for list selection;
4. grouping temporary pages pins them, preserves order, and creates one fixed
   group;
5. undo and redo restore/reapply pinning, drag topology, grouping, and renaming;
6. undoing single and batch closes restores exact placement, group membership,
   active selection, history, and list context;
7. one compound gesture creates one undo action;
8. expand/collapse does not create an undo action;
9. legacy persisted navigation locations still decode.

Run the focused tests first, then the complete Swift test suite, then build and
ad-hoc-sign the development app. Finally, manually exercise the five reported
flows in the built app.
