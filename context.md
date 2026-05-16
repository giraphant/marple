# reader/ Context

Long-form developer notes for the `reader/` SPA. For user-facing run /
feature docs see [`README.md`](./README.md). This file describes
architecture, design decisions, and how to extend the system.

## Purpose

Card-style **typed-object browser + Markdown editor** over the qua vault.
Originally built to support a 2–3 万字 literature-review chapter; now the
primary long-term knowledge-base UI for the vault (which keeps growing
through `quasi` processing pipelines). Built outside Obsidian because
Obsidian's eager indexing is sluggish at 12 k+ entries.

Hard guarantees the design rests on:

- **Vault is the source of truth, not the SPA's state.** Edits round-trip
  to disk; reload restores everything. localStorage holds only ephemera
  (open tabs, settings).
- **LLM-generated and human-written content are separable.** Everything
  in `vault/notes/` is human; everything else is generated. Editing of
  LLM content is gated by an opt-in setting.
- **Git is the backup / sync / undo layer.** Soft-delete moves files to
  `.trash/`; no in-app "permanent undo" is needed beyond `git checkout`.

## Architecture overview

```
[ vault/**/*.md (12 k files) ] ──┐
                                 │  build-index.mjs (one-shot)
                                 ▼
                  data/index.json (~5 MB, one row per md)
                                 │
                                 │ fetched once on app boot
                                 ▼
        ┌──────────── App.tsx (state hub) ────────────┐
        │  entries[]  tabs[]  settings   indexes      │
        └──────┬──────────────┬───────────────────────┘
               │              │
               ▼              ▼
        Sidebar / TabBar   ListView / DocView / ThemesView / TrashView
                                            │
                                            │ on edit / create / delete
                                            ▼
                       PUT POST DELETE /vault/**/*.md
                            (serve.mjs, ~250 lines)
                                            │
                                            ▼
                                  Filesystem ⇄ git
```

Two long-running processes when developing:

- **vite** on `:5173` — serves the SPA, HMR
- **serve.mjs** on `:5174` — Node static server + write-back; vite proxies
  `/vault/*`, `/api/*`, `/sources/*`, `/reader/data/*` to it

Production: `npm run build` writes `dist/`; `serve.mjs` serves the same
`dist/` and handles writes in one process.

## Key concepts

### Entry & EntryType

A frontmatter-parsed row from `data/index.json`. Defined in `types.ts`.
6 canonical types: `paper-analysis / book-overview / chapter-summary /
author-profile / topic-synthesis / note`. Build-index applies a `TYPE_ALIAS`
map to collapse legacy aliases (`paper`, `monograph`, `journal-article`,
…) to the canonical form.

Each `Entry` carries: `path`, `type`, `title`, `author`, `year`, `rating`
+ `rating_score` (computed from `★★★` → 3), `themes[]`, `topic`, `source`,
`doi`, `chapters_analyzed`, `annotates`, `created`, `pdf_slug`,
`has_pdf`, and a 320-char `preview` from the first body paragraph.

### Tab system

Each tab holds a **history of TabContent** + a cursor (browser-style
back/forward). Defined in `types.ts`:

```ts
type TabContent =
  | { kind: 'list'; type: EntryType }   // a type's card grid
  | { kind: 'doc'; path: string }       // an entry's 3-pane reader
  | { kind: 'themes' }                  // themes index
  | { kind: 'trash' };                  // .trash/ browser

interface Tab {
  history: TabContent[];
  cursor: number;
  pinned?: boolean;
}
```

Click semantics (App.tsx):

- **Sidebar item / wiki link / chapter / "回到本书"** → `navigateInActiveTab`
  pushes new content into the active tab's history
- **Card click** → same (navigates in current tab)
- **Cmd / Ctrl + Card click** → `openInNewTab`
- **+ tab** in tab bar → empty new ListTab
- **Drag tab** → reorder (pinned and unpinned can't cross)
- **Cmd+[ / Cmd+]** → back / forward
- **Middle-click / ×** → close
- **📌** on active tab → pin (moves to end of pinned region)

The history model means individual tabs preserve "where I was looking"
across user-driven navigation, instead of state being global. State that
doesn't logically belong per-tab (filter/query/scroll) is still global —
a deliberate simplification; promote to per-tab when it bites.

### Editing pipeline

Two layers:

1. **Frontmatter properties** — `PropertyPanel.tsx` rows are click-to-edit
   (rating, year, author, source, DOI, topic, themes chips). Each save
   calls `patchFrontmatter(path, mutate)` which GETs the file, parses
   YAML, applies the mutation, re-serializes, PUTs back. The in-memory
   entry is updated optimistically.

2. **Body** — `NoteEditor.tsx` mounts a CodeMirror 6 instance with a
   custom Ulysses-flavored `HighlightStyle` + theme. Edits debounce 1.5 s
   then `replaceBody(rawText, newBody)` + PUT. Switching tabs / closing
   drawer flushes pending writes; `beforeunload` guards.

   Body edit is gated: only `note` entries are editable by default. The
   setting `allowEditLLMBody` toggles editing for paper/book/author/topic/
   chapter — disabled by default since those are reprocess targets.

`frontmatter.ts` is the YAML parse / serialize layer. Tuned so writebacks
diff cleanly:

- Inline flow arrays preserved (`themes: [a, b, c]`)
- Empty scalars stay bare (`year:` not `year: null`)
- `flowCollectionPadding: false` keeps brackets tight
- Body's leading newline is preserved so `---\n\n# H1` doesn't lose its
  blank line (a real bug we fixed — see Git log)

### Icons

Two separate concerns:

- **TypeIcon** (`TypeIcon.tsx`) — colored chip with a Phosphor icon for
  one of 6 types. Used in Sidebar, TabBar, MiniRow. Each type maps to
  bg-X-100 + text-X-700 from Tailwind.
- **Icon** (`Icon.tsx`) — chrome icons (plus, x, gear, trash, pencil,
  dots-three, caret-left/right, pin / pin-fill). Single color
  (`currentColor`), no chip.

Both are sourced from **unplugin-icons + @iconify-json/ph** —
Phosphor regular. Build-time SVG inlining; tree-shake friendly. Adding
an icon = one `import PhFoo from '~icons/ph/foo'` + one case in the
switch. See "How to extend" below.

### Annotations

`vault/notes/` is the only directory whose files are human-written.
Notes have one optional field — `annotates: <vault-relative path>` —
that turns the note into an annotation pinned to that target. The same
note file shape is used for free idea notes (no `annotates`).

The split is **soft and reversible**: any idea note can be promoted to
an annotation by adding the field; any annotation can be unpinned by
removing it. No directory split, no special file shape, no migration.

UI surface:

- `App.annotationIndex` keys notes by their `annotates` path
- `PropertyPanel` on non-note entries lists "我的批注 (N)"
- On a note's DocView, a rose chip "批注于 …" links back to target
- "+ 新建批注" button on non-notes / "+ 新建 note" in sidebar both call
  POST `/vault/notes/<slug>.md`

### Reading typography

One slider in Settings ("字号" + family + 行高) drives **both** the
rendered article and the markdown editor. The mechanism is plain CSS
variables — no React tree pass, no editor rebuild on font tweaks.

**Flow**:

```
settings.{fontFamily,fontSize,lineHeight}
        │
        │  useEffect in app.tsx, writes vars on <html>
        ▼
  :root {
    --reader-font-family: <stack>;
    --reader-font-size:   16px;
    --reader-line-height: 1.78;
  }
        │  inherited via CSS cascade
        ├──▶ .prose-body          (rendered article, styles.css)
        └──▶ .cm-scroller         (CodeMirror, NoteEditor.tsx theme)
```

**Convention** (mirrors Obsidian's `--font-text-*` vs `--font-ui-*`):

| Surface | Sizes from | Rationale |
|---|---|---|
| Article + editor ("reading content") | `var(--reader-font-*)` | one knob, slider-driven, user-controlled |
| Sidebar, TabBar, PropertyPanel, cards, SettingsPanel ("chrome") | Tailwind utilities (`text-[11px]`, `text-[12px]`, …) | fixed UI density, not affected by reader slider |

**Scaling rule for reading content**: headings / code / blockquote
inside `.prose-body` and `.cm-*` use **`em`** (relative to body),
never `rem` or `px`. The Tailwind Typography plugin uses the same
trick — rem on container, em on children — so the whole subtree
scales as a unit when the slider moves. If you add a new element
inside `.prose-body` or a new highlight class in the editor theme,
follow this rule or scaling will silently break.

**Pitfalls**:

- A `font-size: 1.05rem` on a new prose element will look right at
  the default 16 px and silently fail to scale.
- A new chrome component that copies `.prose-body` styling will
  inherit the reader slider — keep chrome on Tailwind utilities.
- CSS vars are inherited from `<html>`, so anything portaled into
  `document.body` (modals, popovers) also picks them up — that's
  usually fine since they sit inside the reading flow.

### Trash

`DELETE /vault/notes/<name>` moves the file to
`vault/notes/.trash/<base>.<ISO ts>.md` (timestamp suffix prevents
collisions when the same name is deleted twice). `build-index` skips
dot-prefixed directories so `.trash` is automatically off the live index.

`/api/trash/{list,restore,purge}` endpoints power `TrashView`.
`.trash/` is gitignored (root `.gitignore`) — git history is the
permanent recovery layer.

## Component map

| File | Responsibility |
|---|---|
| `src/main.tsx` | Vite entry; renders `<App/>` into `#app` |
| `src/app.tsx` | State hub: entries, tabs, settings, all indexes, action callbacks |
| `src/components/Sidebar.tsx` | 240 px left rail: workspace name, "+ note", type list, 横切视图 (主题), trash, settings |
| `src/components/TabBar.tsx` | Top tab bar: back/forward, tabs, +, pin / drag / close |
| `src/components/ListView.tsx` | Header (title, count, search, rating filter, theme chip), Dashboard, card grid + load-more |
| `src/components/Card.tsx` | One card in the grid |
| `src/components/MiniRow.tsx` | One row inside property panel back-links |
| `src/components/Dashboard.tsx` | Type stats: top themes, top-rated, count |
| `src/components/DocView.tsx` | 3-pane reader: chapters rail / main body / property panel; auto-save loop lives here |
| `src/components/NoteEditor.tsx` | CodeMirror 6 wrapper. Ulysses theme. Compartment-based hot reconfigure for settings change |
| `src/components/PropertyPanel.tsx` | Right rail: ActionsRow (citation / PDF), editable fields, themes chips, derived back-links, "+ 新建批注" |
| `src/components/ThemesView.tsx` | Theme index across all entries: chip grid sorted by count, with type breakdown dots |
| `src/components/TrashView.tsx` | `.trash/` browser: restore / purge buttons |
| `src/components/SettingsPanel.tsx` | Floating settings: font / size / line-height / allow LLM body edit |
| `src/components/TypeIcon.tsx` | Colored Phosphor chip per EntryType |
| `src/components/Icon.tsx` | Chrome icons from `~icons/ph/*` |
| `src/types.ts` | `Entry`, `EntryType`, `Tab`, `TabContent`, `TYPES` registry |
| `src/api.ts` | All HTTP helpers + path slug generation for new notes |
| `src/frontmatter.ts` | YAML parse / serialize tuned for diff-clean writes |
| `src/wiki.ts` | `[[wikilink]]` index + author splitter |
| `src/settings.ts` | Settings type + `loadSettings` / `saveSettings` (localStorage) |
| `scripts/build-index.mjs` | Walks `vault/`, scans `sources/` for PDFs, emits `data/index.json` |
| `serve.mjs` | Static server + write-back endpoints |
| `vite.config.ts` | Vite + preact preset + unplugin-icons + dev proxy |

## How to extend

### Add a new icon

1. Pick one at https://phosphoricons.com (regular weight to match
   existing). Note its kebab-case name.
2. In `src/components/Icon.tsx`: add `import PhWhatever from '~icons/ph/whatever';`,
   extend `IconName` union, add a case in the `COMPONENT` map.
3. Use it: `<Icon name="whatever" size={14} class="text-stone-500" />`.

No path-copying. unplugin-icons inlines the SVG at build time.

### Add a new TabContent kind

1. Extend `TabContent` union in `types.ts`.
2. In `App.tsx`: add navigation helpers (`openSomething`) that call
   `navigateInActiveTab({ kind: 'whatever', ...params })`.
3. Add a `<WhateverView ...>` branch to the main-area JSX based on
   `activeTabContent?.kind`.
4. In `TabBar.tsx → tabDisplay`: add an icon + title for the new kind.
5. In `App.tsx`'s `loadTabs` validator: allow the new kind through.

### Add a new editable frontmatter field

1. Extend `Entry` in `types.ts`.
2. In `build-index.mjs`: read it from `fm.<field>` and push into entry.
3. In `api.ts → applyFmToEntry`: merge the field on optimistic update.
4. In `PropertyPanel.tsx`: add a `<TextRow label="…" field="…" save={save} />`
   row (or write a custom row for special editors like rating / themes).

### Add a new HTTP endpoint

1. Add a handler in `serve.mjs`. Mirror the existing security pattern:
   `resolveSafe` → path constraint (e.g. must be under `vault/notes/`) →
   extension check → existence check → atomic write.
2. Route it in the request switch (or extend `matchTrashRoute` for `/api/*`
   shapes).
3. Add a client helper in `api.ts`.

### Add a new icon set

`npm install -D @iconify-json/<setname>`. Then `~icons/<setname>/<name>`
is importable immediately. No vite config change needed.

## Recent Changes

- 2026-05-16: v0.9.0 — typed body renderers, sidebar collapse,
  citation formats, EPUB-style book rail.
  - New `src/body/` package. Splits the article body by `## H2` and
    routes typed sections to specialised renderers; unknown sections
    fall back to plain `marked`. Lives in `BodyView.tsx`.
    - `ConceptTable` — `## 关键概念` / `## 核心概念谱系`. Header-driven
      column roles (`概念 / 英文 / 提出者 / 出现章节 / 定义 / 来源作品 /
      演化轨迹 / 当前状态`). Refs column splits on `,，、` into chips;
      coiner/status render as chips; prose columns get min-widths so
      the table overflows to horizontal scroll at narrow viewports
      instead of compressing to vertical-Chinese single-char columns.
    - `QuoteCards` — `## 可引用观点` / `## 金句要点` / `## 可引用段落`.
      Pink-bordered cards, Georgia-first serif so English renders at
      full proportions, copy-with-source button (clipboard).
    - `ProjectTabs` — `## 项目关联` / `## 与项目主题的关联` / `##
      相关引用文献`. Each `### H3` becomes a tab; renders even with
      a single H3 (uniform UI, the tab strip labels the project).
    - `ChapterFlow` — `## 章节(间)?逻辑` AND `## 学术轨迹` (same
      `**bold prefix**` paragraph shape). Vertical timeline with dots
      on the line (ring-page mask "cuts" the line through each dot).
      Requires `!pl-0` to beat `.prose-body ol { padding-left: 1.5em }`'s
      class+element specificity.
    - `ReadingList` — `## 推荐精读章节`. Numbered cards with badge.
    - `WorksList` — `## 代表著作`. Per-book cards parsed from
      `[[wikilink|Title]]（year）描述`. Year chip + rating star if the
      wiki target resolves to a vault entry. Clickable title navigates
      via the SPA tab system.
    - `IntroLead` — `## 思想肖像`. Lede-paragraph treatment (15px,
      1.85 line-height, amber-300 left rule).
    - `TheoryNetwork` — `## 理论网络`. Per-theorist card with bold
      name + comma-split keyword chips + relationship prose.
  - **Sidebar collapsible**: 240px → 56px icon-only via Cmd+B or
    chevron in header. `settings.sidebarCollapsed` persisted.
  - **Sidebar drag-reorder**: HTML5 drag on the 6 object-type rows;
    order saved to `settings.typeOrder` and consumed by
    `orderedTypes(settings)` in App.
  - **DocView chapter rail** (EPUB-style): also shows on chapter pages
    (not just on book-overview); rail header has a "概述" link back to
    the book overview; current entry highlighted; chapter titles
    single-line `truncate` with hover tooltip.
  - **PropertyPanel works/siblings split by type**: "作品 (N)" /
    "同作者 · ..." sections split into 图书 / 论文 sub-groups (render-
    time filter on `backlinks.works` / `backlinks.siblings`).
  - **Citation formats**: 4 presets (`inline-en` / `inline-zh` / `title`
    / `markdown`) in `citation.ts`. Default chosen in Settings → 引用;
    inline ▾ menu next to the 复制引用 button switches on the fly.
  - **Type label**: 书 → 图书 so all 6 type labels are 2-char and align
    in the sidebar.
  - **Sidebar text labels**: `Object types` → `物件`, `横切视图` → `视图`.
  - **H2 styling**: dropped the GitHub-readme `border-bottom` on h2;
    rely on `margin-top: 2em` + weight for section breaks. First h2/h1
    in an article gets a shrunk top margin so the doc doesn't open
    with a giant gap.
  - **PropertyPanel width**: 320px → 288px (`w-72`).

- 2026-05-15: v0.8.7 — per-type property panel field visibility.
  - `PropertyPanel` used to render the full row set
    (rating/year/author/source/DOI/topic/chapters_analyzed) for every
    entry type. Author profiles, notes, and topic syntheses were
    showing 5+ irrelevant "—" rows since those fields don't exist in
    their underlying schemas.
  - Added `FIELDS_BY_TYPE` map at the top of `PropertyPanel.tsx`,
    keyed by `EntryType`, listing the property rows that apply per
    type. Source of truth — edit this when adding a new field or
    type. Notes show no metadata rows at all (the `annotates` chip
    surfaces separately above).

- 2026-05-15: v0.8.6 — heading scale fix after typography unification.
  - The article body baseline went from a hard-coded 14 px to the
    settings-driven 16 px (default) in v0.8.5. The old heading scale
    (h1=1.5em, h2=1.2em, h3=1.05em) was calibrated against the 14 px
    body — at 16 px body those ratios collapsed to near-flat (h3 was
    only ~5 % larger than body and looked indistinguishable).
  - New scale matches the editor's `.cm-h1/2/3/4` ratios exactly so
    read and edit modes share the same visual hierarchy:
    h1=1.7em / h2=1.4em / h3=1.2em / h4=1.08em / h5+h6=1em. Added h4–h6
    explicitly (previously they inherited body styling).
  - When tuning heading sizes in the future, change both
    `.prose-body h*` in `styles.css` and `.cm-h*` in
    `NoteEditor.tsx`'s `buildEditorTheme` together.

- 2026-05-15: v0.8.5 — unified reading typography (Obsidian-style).
  - The "字号 / 字体 / 行高" settings used to only style the CodeMirror
    editor; the rendered article was hard-coded `text-[14px]` with
    `rem`-sized headings (`DocView.tsx` + `styles.css`). Same content
    looked different in edit vs read mode.
  - Refactored to a single source of truth: three CSS variables
    (`--reader-font-family / --reader-font-size / --reader-line-height`)
    written to `<html>` by `app.tsx`. Both `.prose-body` (article) and
    `.cm-scroller` (CodeMirror) read from them via plain CSS. Headings,
    code, blockquote inside `.prose-body` switched from `rem` to `em` so
    the whole subtree scales when the slider moves.
  - `EditorThemeConfig` collapsed to just `{ dark: boolean }` — font
    fields are no longer props, so font tweaks don't trigger
    `themeCompartment.reconfigure` (caret / undo / scroll preserved).
  - See "Reading typography" in Key concepts for the contract that
    future components should follow.

- 2026-05-15: v0.8.4 — persistent chapter rail on chapter pages.
  - `DocView` previously rendered the left章节 rail only when
    `entry.type === 'book-overview'`. Clicking into a chapter dropped the
    rail, forcing the user back through the overview to reach a sibling
    chapter. The rail now also renders for `chapter-summary` entries —
    keyed on `entry.book` (chapters carry this in frontmatter; overviews
    derive it from the directory slug via `bookSlugOf`).
  - The rail now includes the book overview as a top "↑ 概览" item, and
    highlights whichever entry is currently open (`bg-surface-2` +
    left accent border). The existing "↑ 回到本书" header button is
    redundant but kept for muscle memory.

- 2026-05-15: v0.8.3 — align with quasi 0.15.x schema (plural `authors`).
  - **build-index** now reads `fm.author ?? fm.authors` for the author
    field. The quasi 0.15.x schema (`schemas/book.py`, `schemas/paper.py`)
    canonicalizes the field to `authors: list[Name]` (plural array,
    required, ≥1 element). Older book overviews still use `author:`
    (singular string or wiki-link array); the fallback handles both.
  - **Data status** (snapshot): of 910 book overviews, 516 have neither
    `author` nor `authors` in frontmatter — they were generated by a
    pre-0.15 quasi build that didn't emit author at all. Backfilling
    happens out-of-band in a separate worktree; the reader needs no
    further changes once those frontmatter writes land on main.

- 2026-05-15: v0.8.2 — author-profile backlink fixes + grouped siblings.
  - **build-index** now reads `fm.title || fm.name` for the entry title.
    Earlier 16 author profiles in `vault/authors/` used `name:` instead of
    `title:` and were silently un-indexed for the author→works lookup
    (their `entry.title` was `null`, so PropertyPanel's
    `(entry.title ?? '').toLowerCase().trim()` key never matched any
    work's `author` field).
  - **PropertyPanel** splits the author-profile "作品" section into two
    groups, "书 (N)" and "论文 (N)", instead of one flat list.
  - **PropertyPanel siblings** ("同作者其他", shown on paper/book pages)
    also split by type — "同作者其他·书 (N)" + "同作者其他·论文 (N)".
    Replaced the global top-8 cap with per-group top-8, so one type can't
    crowd out the other when an author has many works in both.

- 2026-05-14: v0.7.0 — themes index + citation + PDF.
  - **ThemesView**: cross-type tag index. Chip grid sorted by count;
    each chip shows total + per-type breakdown dots. Click → filter that
    theme on the type where it's most common. Search box + "出现 ≥ N"
    threshold. New `{ kind: 'themes' }` TabContent.
  - **ActionsRow in PropertyPanel** (paper / book only):
    - 复制引用 → markdown citation
      `Author (year). *Title*. Source. https://doi.org/DOI` to clipboard
    - 打开 PDF → `window.open(/sources/<pdf_slug>.pdf)`, gated on `has_pdf`
  - **build-index** scans `sources/` for top-level `*.pdf`, computes
    `pdf_slug` (paper basename / book directory slug) and `has_pdf` for
    each entry. Current vault: 569 PDFs match 514 entries (436 books +
    78 papers).
  - **serve.mjs MIME** adds `.pdf → application/pdf`.

- 2026-05-14: v0.6.0 — Capacities-inspired layout + real tab system +
  unplugin-icons.
  - **Left sidebar** (240 px) with workspace name / "+ note" / type list /
    横切视图 (主题) section / trash + settings at bottom. TypeIcon brings
    Capacities-style colored chips per type (TypeIcon.tsx).
  - **True tab system** with history per tab. Tab kinds: `list` / `doc` /
    `themes` / `trash`. Browser-style ← → (Cmd+[, Cmd+]). Pin / drag /
    middle-click / × / + new tab. Drawer overlay model removed in favor
    of `DocView` filling the main area (Reader.tsx replaced).
  - **Card click** = navigate in current tab. Cmd/Ctrl+click = new tab.
    Matches Obsidian / browser muscle memory.
  - **Trash browser** via `/api/trash` (GET list / POST .../restore /
    DELETE .../<name>). `vault/notes/.trash/` is gitignored.
  - **unplugin-icons + @iconify-json/ph** replaces hand-copied SVG path
    map. `~icons/ph/<name>` virtual modules; tree-shake; new icon =
    one-line import. Bundle 236→240 KB gzip.

- 2026-05-14: v0.5.0 — Markdown editor, auto-save, soft-delete, settings.
  CodeMirror 6 + lang-markdown; Ulysses-flavored theme; auto-save 1.5 s
  debounce; settings panel (font/size/line-height + LLM body toggle);
  soft delete with ISO-ts trash.

- 2026-05-14: v0.4.0 — personal notes + annotation system.
  `vault/notes/`; `annotates:` field; reverse-link UI;
  "+ 新建批注" button; `POST /vault/notes/`.

- 2026-05-13: v0.3.0 — editable properties + Vite/TS stack.
  Migrated CDN single-file → Vite 5 + TS + Preact; YAML library;
  inline-edit property rows; PUT `/vault/**/*.md`.

- 2026-05-11: v0.2.x — Capacities-style typed surface + Obsidian wiki
  links.

- 2026-05-11: v0.1.0 — initial card-style MVP.

## Dependencies

Runtime: Node ≥ 18.

Production (`dependencies`):

- `preact` — framework
- `marked` — markdown → HTML (read mode)
- `yaml` — frontmatter parse / serialize
- `codemirror` + `@codemirror/{state,view,commands,language,lang-markdown}` + `@lezer/highlight` — editor
- `motion` (vestigial; unused after revert)
- `htm` (vestigial; unused)

Dev (`devDependencies`):

- `vite` + `@preact/preset-vite` — build / dev server
- `unplugin-icons` + `@iconify-json/ph` + `@svgr/{core,plugin-jsx}` — icons
- `typescript` + `@types/node`
- `tailwindcss` + `postcss` + `autoprefixer` — styling
- `concurrently` — `npm run dev` parallel processes

## Known Issues / Tech Debt

- **CodeMirror still in main bundle** (~200 KB gzip of 240 KB).
  Lazy-load when first opening an editable entry would cut cards-view
  initial load.
- **No `[[` autocomplete in editor** yet. CodeMirror autocomplete API
  + vault entries as source is straightforward but not wired.
- **Focus mode / typewriter scroll** unimplemented. Compartment hooks
  in `NoteEditor` are placeholders.
- **Themes are still strings**, not first-class objects. Capacities-style
  promotion (each theme has its own `vault/themes/<slug>.md` page with
  description + back-links) is on the roadmap. Suggested approach:
  optional — if `vault/themes/<slug>.md` exists, its body shows up when
  you click that chip; nothing else changes.
- **YAML writeback drops original double quotes** on plain scalars
  (`author: "Anna Harris"` → `author: Anna Harris`). Equivalent YAML,
  but cosmetic diff. Fixable by parsing through `yaml.Document` AST
  preserving per-node style.
- **No file watcher.** Run `npm run build:index` after vault changes
  to refresh `data/index.json`.
- **All 12 k+ cards render at once** in ListView — fine due to
  `content-visibility: auto`, but real virtualization (e.g. `@tanstack/virtual`)
  would scale better as the vault grows past 20 k.
- **POST endpoint is scoped to `vault/notes/` only.** Creating new
  paper / book / author entries from the reader isn't supported; those
  come from `quasi` processing.
- **Notes carry no metadata UI** for rating / year / author / DOI by
  design — those rows render as `—` in PropertyPanel. The editor wires
  are there if a note ever needs metadata.
- **Trash restore doesn't refresh the in-memory index live.** The file
  is restored to vault/notes/ but won't show up in card lists until the
  next page reload or `build:index` run. A live "refresh entries" action
  would close the loop.

## API Surface

Frontend npm scripts:

- `npm run dev` → vite + serve.mjs concurrently
- `npm run dev:vite` → vite only (if serve.mjs already running)
- `npm run build` → `build:index` then production bundle to `dist/`
- `npm run build:index` → regenerate `data/index.json`
- `npm run serve` → start static + write-back server on `PORT` (default 5174)
- `npm run typecheck` → `tsc --noEmit`

Backend HTTP endpoints (`serve.mjs`):

| Method | Path | Purpose |
|---|---|---|
| GET | `/reader/*`, `/vault/*.md`, `/sources/*.pdf`, `/reader/data/*` | static files |
| PUT | `/vault/**/*.md` | update existing md (frontmatter or body) |
| POST | `/vault/notes/**/*.md` | create new note (409 if exists) |
| DELETE | `/vault/notes/**/*.md` | soft-delete (move to `.trash/`) |
| GET | `/api/trash` | list trashed notes |
| POST | `/api/trash/<name>/restore` | move back to `vault/notes/` |
| DELETE | `/api/trash/<name>` | permanent delete |

All write endpoints share these defenses:

- Path must resolve under `ROOT` (no `../` escape)
- `vault/notes/` scope for POST / DELETE
- Must be `.md`
- PUT requires existing target + `---` fence
- 5 MB body cap
- Atomic via temp file + rename
