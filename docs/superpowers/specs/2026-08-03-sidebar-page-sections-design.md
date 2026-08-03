# Sidebar Page Sections Visual Design

## Goal

Present fixed and temporary pages as one visual `页面` area while retaining the
two existing outline sections and all of their current behavior.

The layout follows Arc's page stack: fixed pages appear first, temporary pages
appear after a lightweight divider, and an always-available New Tab action sits
immediately before the temporary list.

## Visual States

The visible order depends only on whether fixed and temporary pages exist:

| Fixed pages | Temporary pages | Visible order |
| --- | --- | --- |
| none | none | `页面` → `＋ 新建页面` |
| none | present | `页面` → divider → `＋ 新建页面` → temporary pages |
| present | none | `页面` → fixed pages → `＋ 新建页面` |
| present | present | `页面` → fixed pages → divider → `＋ 新建页面` → temporary pages |

The divider is therefore controlled by the presence of temporary pages, not by
the presence of fixed pages. There is no `Clear` action.

## Outline Structure

The existing `.pinned` and `.tabs` root sections remain separate:

- `.pinned` remains the fixed-page container and the drop target that accepts
  pages even when it has no children;
- `.tabs` remains the temporary-page container and the drop target used to
  unpin or reorder temporary pages.

Only their presentation changes:

- the `.pinned` section's visible title becomes `页面`;
- the `.tabs` section no longer renders a second text title;
- the `.tabs` section header renders the optional divider and the New Tab
  control before its existing temporary-page children.

Using the existing `.tabs` section header avoids a synthetic outline node and
keeps selection, context menus, drag payloads, undo, and persistence unchanged.
Existing section expansion state also remains unchanged.

## New Tab Control

The New Tab control is a full-width, plain sidebar row with a leading plus icon
and secondary text. It has no selected state and is not a draggable page.

Its action is exactly the existing Command-T action:

```swift
CommandPalettePresenter.toggle(model: model)
```

It opens or toggles the global search panel and does not call
`AppModel.newTab()` or create a blank note.

The localized label is `新建页面` in Chinese and `New Tab` in English.

## Scope Boundaries

This is a presentation-only change. It does not alter:

- `Workspace`, `NavTab`, or persisted-state schemas;
- fixed anchors or Command-W withdrawal;
- pinning, unpinning, grouping, ordering, or multi-selection;
- sidebar undo and redo;
- context-menu actions;
- the existing drag-and-drop routing for either section.

A hover close button, Arc Peek, and `Clear` remain outside this change.

## Verification

Automated coverage should verify:

1. the four fixed/temporary combinations produce the specified header,
   divider, New Tab, and page-row order;
2. activating New Tab routes to the same command-palette presenter as Command-T;
3. New Tab never becomes the active outline selection or a drag source;
4. the empty `.pinned` section remains expandable and accepts single and batch
   drops;
5. existing temporary-page activation and fixed-page grouping tests remain
   green.

Manual verification should compare all four states in both light and dark
appearance and confirm that the divider and New Tab align with ordinary page
rows without introducing a second visible section title.
