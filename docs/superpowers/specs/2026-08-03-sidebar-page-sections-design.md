# Sidebar Page Sections and Menu Simplification Design

## Goal

Present fixed and temporary pages as one visual `页面` area while retaining the
two existing outline sections, their page children, and their drag/drop
routing. Remove the niche `关闭其他页面` action from every tab UI.

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

The existing `.pinned` and `.tabs` logical sections remain separate:

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
  visible row has exactly the same y-coordinate as if no row intervened;
- `.tabs` remains a semantic section but is not reported as an AppKit group
  item. Source-list group rows receive an automatic 13-point leading gap; not
  using that appearance lets the 13-point divider row sit directly between
  the adjacent 30-point page rows, with 6.5 points on each side of the line;
- the outline data source presents the `.tabs` divider and its temporary-page
  children as root-level peers. The node still owns those children internally,
  so lookup and drop routing keep using the existing logical section, while
  AppKit no longer adds a child indentation level to the visible rows;
- the `.tabs` disclosure cell stays hidden. It retains its existing logical
  expandability for drop targeting, but expanding it yields no additional
  visual rows because its children are already present in the flattened list;
- the divider line has no additional horizontal inset inside its cell. The
  fixed-page cell, divider cell and temporary-page cell therefore share the
  same leading and trailing bounds;
- between-row drops in the flattened temporary area arrive from AppKit with a
  root-list child index. The outline delegate translates that index once into
  the existing `.tabs`-local insertion index before validation or acceptance;
  model-level ordering and drop operations remain unchanged.

Using the existing `.tabs` section header avoids a synthetic outline node and
keeps selection, remaining context menus, drag payloads, and persistence
unchanged. Visual flattening is confined to the outline data-source boundary;
it does not change `Workspace`, `NavTab`, or persisted section data.

## Context Menu Simplification

Remove `关闭其他页面` globally rather than hiding it in only one sidebar:

- remove the item and selector from the AppKit sidebar context menu;
- remove the item from `TabStripView`;
- remove the now-unreferenced `AppModel.closeOtherTabs(_:)` operation, its
  dedicated undo test, and its localization key.

Ordinary `关闭页面`, Command-W withdrawal, and explicit multi-selection closing
remain unchanged. No replacement action or shortcut is introduced.

## Scope Boundaries

Aside from removing the dedicated `关闭其他页面` operation, this change does not
alter:

- `Workspace`, `NavTab`, or persisted-state schemas;
- fixed anchors or Command-W withdrawal;
- pinning, unpinning, grouping, ordering, or multi-selection;
- undo and redo for the remaining sidebar actions;
- context-menu actions other than `关闭其他页面`;
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
4. with source-list styling, `.tabs` is not a group item, has no disclosure
   cell, and its visible divider row directly touches the fixed and temporary
   row rectangles above and below;
5. fixed-page, divider, and temporary-page cells have identical horizontal
   bounds, and the divider line fills those bounds without an extra inset;
6. neither tab UI contains `关闭其他页面`, and no dedicated
   `closeOtherTabs(_:)` API, undo test, or localization remains;
7. the empty `.pinned` section remains expandable and accepts single and batch
   drops;
8. existing temporary-page activation, fixed-page grouping, ordinary close,
   and multi-selection close tests remain green;
9. single and batch drops before, between, and after visually flattened
   temporary rows preserve their requested local insertion position.

Manual verification should compare all four states in both light and dark
appearance and confirm that the divider appears only between non-empty fixed
and temporary lists, without introducing a second visible section title or an
empty gap. The divider and every page row below it must align horizontally with
the fixed-page rows above it.
