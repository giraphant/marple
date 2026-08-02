# Pinned Page Anchor Design

## Goal

A pinned page keeps one durable anchor while its tab remains free to navigate
through related pages. The pinned page is an identity, not an alias for whatever
the tab happens to be displaying now.

For example, pinning `Development as Freedom` and then opening chapter 4 keeps
the pinned row named and typed as `Development as Freedom`. Pressing Command-W
withdraws the chapter excursion and returns the reader to the pinned book.

## Model

`NavTab` stores one optional pinned anchor in addition to its existing navigation
history:

- an unpinned tab has no anchor;
- pinning captures the tab's current `NavLocation` as its anchor;
- navigation continues to push ordinary locations onto the existing history;
- unpinning removes the anchor without changing the current page;
- Command-W on a pinned tab replaces the excursion with the anchor;
- Command-W while already at the anchor is a no-op.

The anchor is the pinned tab's stable identity. Sidebar title, type icon, pinned
middle-list membership, cached title/type, and sharing use the anchor. The reader
and its back/forward controls use the current history entry.
Existing per-document scroll memory restores the anchor document's in-session
reading position when Command-W returns to it.

## Persistence

No persisted-state schema change is required. When a tab is pinned, the existing
`PersistedTab.location` stores its anchor rather than its current excursion.
Restoring that tab therefore starts it at the anchor with a fresh history, as it
does today. An unpinned tab continues to persist its current location.

State written before this feature has no recoverable original pin location.
Each legacy pinned tab therefore adopts its currently persisted location as its
anchor on first restore. New pin operations are exact from that point onward.

## Commands and Closing

Command-W has two page-level meanings:

- temporary page: close the page using the existing undoable close path;
- pinned page: return to the anchor and keep the pinned page.

The sidebar context menu's **Close Page** action remains the explicit way to
remove a pinned page. A hover close button and a Peek-style overlay are outside
this change.

## Undo

Pin and unpin remain sidebar undo operations. Their snapshots include the
optional anchor so undo and redo restore the pinned identity without rewinding
navigation that occurred after the structural action. Closing and restoring a
pinned page continue to carry the entire live `NavTab`, including its anchor.

## Verification

Tests cover these observable behaviors:

1. Pinning captures the current location as a stable anchor.
2. Navigating within a pinned tab changes the reader but not its sidebar identity.
3. Command-W after one or several navigations returns to the anchor and discards
   the excursion; Command-W at the anchor does nothing.
4. Back and forward continue to work before withdrawal.
5. Unpinning keeps the current page and removes pinned-anchor behavior.
6. Pin undo/redo and direct context-menu close retain their existing semantics.
7. Persistence restores pinned tabs at their anchors without a schema migration.
