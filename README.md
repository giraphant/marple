# qua reader (v0.5)

Card-style reader over the qua vault with a Markdown editor for personal
notes and annotations. Vite + TypeScript + Preact + CodeMirror 6; backend
is a tiny Node static server that handles `GET / PUT / POST / DELETE`
on `vault/`.

## Layout

```
reader/
  index.html                # Vite entry (loads src/main.tsx)
  src/
    main.tsx                # render <App/>
    app.tsx                 # top-level container
    types.ts                # Entry shape + canonical type registry
    api.ts                  # GET/PUT helpers, patchFrontmatter
    frontmatter.ts          # yaml-based parse / serialize
    wiki.ts                 # [[wikilink]] index + resolver
    styles.css              # Tailwind + custom prose classes
    components/             # Card, MiniRow, Dashboard, Reader, PropertyPanel
  scripts/
    build-index.mjs         # scans ../vault/, writes data/index.json
  serve.mjs                 # static server + PUT /vault/**/*.md endpoint
  vite.config.ts            # /vault and /reader/data proxied to serve.mjs
  data/
    index.json              # generated
```

## Run

First time:

```sh
cd reader
npm install
npm run build:index   # one-time index build
```

Day-to-day dev (vite + serve.mjs concurrently):

```sh
npm run dev
```

`vite` serves the SPA on `http://localhost:5173/reader/`, and proxies
`/vault/*` and `/reader/data/*` through to the Node `serve.mjs` on 5174
(which also handles the PUT writes).

Production build:

```sh
npm run build           # emits dist/
npm run serve           # serve dist + handle vault PUTs in one process
```

## What's in v0.5

- **CodeMirror 6 Markdown editor** with Ulysses-style highlight: markers
  (`#`, `**`, `>`, `-`) stay visible but muted; wrapped content stands out.
  Serif font, generous line-height, no toolbar, no preview pane.
- **Auto-save** debounced 1.5s. Header shows `未保存… → 保存中… → 已保存`.
  Cmd+S flushes immediately. Switching entries or closing the drawer
  flushes pending writes.
- **Settings panel** (⚙ in top bar) — toggle "允许编辑 LLM 生成的正文".
  Default off: only notes are editable, LLM analyses stay rendered.
  When on: every entry opens in the editor.
- **Soft delete**: `⋯` menu on notes → 移到回收站。 Files go to
  `vault/notes/.trash/<base>.<ISO ts>.md` (timestamped to avoid name
  collisions). `build-index` ignores `.trash/`.

## What's in v0.4

- `note` as a 6th type. Personal notes live in `vault/notes/*.md`,
  cleanly separated from LLM-generated analyses.
- Annotations via frontmatter `annotates: <path>` — a note with that
  field shows up in the target's right-panel under "我的批注 (N)"; without
  it, the note is a stand-alone idea.
- "+ 新建批注" button in the property panel of any non-note entry —
  generates the slug, pre-fills frontmatter, POSTs to
  `vault/notes/<slug>-note-<rand>.md`, opens the new note in the reader.
- Note's own drawer shows "批注于 …" chip pointing back to the target.

## What's in v0.3

- Editable `PropertyPanel`: click any property row to edit
  - Rating (1–5★ picker)
  - Year / author / source / topic / DOI (inline text input)
  - Themes (chip add / remove, comma-separated multi-add)
- All edits round-trip through `PUT /vault/<path>.md`; the in-memory
  entry list updates optimistically so backlinks/siblings/similar reflect
  changes immediately
- Diff-friendly YAML writeback: inline `themes: [a, b, c]` stays inline,
  empty values stay bare, `flowCollectionPadding: false`

## What carried over from v0.2

- 5 tabs by `type`: paper / book / chapter / author / topic
- Per-type dashboard (count, avg rating, top themes, top-rated)
- Side-drawer reader with rendered markdown, Esc to close
- `[[wiki-link]]` resolution → navigable; unresolved links struck through
- Derived backlinks (author works, same-author, same-theme)
- Theme-click filter
- Rating filter, free-text search, lazy pagination

## Roadmap (not built yet)

- `[[` autocomplete in the editor (framework is in place, source not
  wired)
- Focus mode + typewriter scrolling toggles (compartment hooks ready)
- Trash recovery UI (currently file-system only)
- Lazy-load the editor module to shrink initial bundle (~200KB)
- File watcher to rebuild index on vault changes
- Real list virtualization for 12k+ cards
- "Create new free-standing idea note" button (separate from annotation)
- Author → works back-reference in card view
- Tauri shell for native window + filesystem watcher
