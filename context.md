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
