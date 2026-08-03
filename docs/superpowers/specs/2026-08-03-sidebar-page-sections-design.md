# Sidebar Page Sections Visual Design

## Goal

Present fixed and temporary pages as one visual `页面` area while retaining the
two existing outline sections and all of their current behavior.

The layout follows Arc's page stack only where it helps this document sidebar:
fixed pages appear first and temporary pages follow. A lightweight divider
separates them only when both lists contain pages.

## Visual States

The visible order depends only on whether fixed and temporary pages exist:

| Fixed pages | Temporary pages | Visible order |
| --- | --- | --- |
| none | none | `页面` |
| none | present | `页面` → temporary pages |
| present | none | `页面` → fixed pages |
| present | present | `页面` → fixed pages → divider → temporary pages |

The divider is therefore controlled by the conjunction of fixed and temporary
pages. It never appears as an orphan line when either side is empty. There is
no New Tab or `Clear` action in the sidebar.

## Outline Structure

The existing `.pinned` and `.tabs` root sections remain separate:

- `.pinned` remains the fixed-page container and the drop target that accepts
  pages even when it has no children;
- `.tabs` remains the temporary-page container and the drop target used to
  unpin or reorder temporary pages.

Only their presentation changes:

- the `.pinned` section's visible title becomes `页面`;
- the `.tabs` section no longer renders a second text title;
- the `.tabs` section header renders only the divider when both sections have
  children;
- otherwise the `.tabs` section returns no cell and occupies no visible
  geometry. AppKit rejects a literal zero row height, so the structural row
  uses `CGFloat.leastNormalMagnitude`; an AppKit probe confirms the following
  visible row has exactly the same y-coordinate as if no row intervened.

Using the existing `.tabs` section header avoids a synthetic outline node and
keeps selection, context menus, drag payloads, undo, and persistence unchanged.
Existing section expansion state also remains unchanged.

## Scope Boundaries

This is a presentation-only change. It does not alter:

- `Workspace`, `NavTab`, or persisted-state schemas;
- fixed anchors or Command-W withdrawal;
- pinning, unpinning, grouping, ordering, or multi-selection;
- sidebar undo and redo;
- context-menu actions;
- the existing drag-and-drop routing for either section.

A sidebar New Tab button, hover close button, Arc Peek, and `Clear` remain
outside this change. Command-T continues to open global search through its
existing command and is not duplicated in the sidebar.

## Verification

Automated coverage should verify:

1. the four fixed/temporary combinations produce the specified single header,
   divider, and page-row order;
2. no New Tab button or second section title is rendered;
3. a hidden `.tabs` structural row has no cell and adds zero y-coordinate
   delta before its first child;
4. the empty `.pinned` section remains expandable and accepts single and batch
   drops;
5. existing temporary-page activation and fixed-page grouping tests remain
   green.

Manual verification should compare all four states in both light and dark
appearance and confirm that the divider appears only between non-empty fixed
and temporary lists, without introducing a second visible section title or an
empty gap.
