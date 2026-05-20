# qua reader

Card-style typed-object browser + Markdown editor over the qua vault.
Browses 12k+ vault entries (papers / books / chapters / authors / topics /
notes), edits frontmatter and note bodies, manages annotations and trash.

Stack: **Vite 8 + TypeScript + Preact + CodeMirror 6 + unplugin-icons (Phosphor)**.
Backend: **Rust (`reader-index` / `reader-api`) + SQLite**. Vite serves
the SPA in dev; Rust builds the SQLite index, handles `/api/*`, vault
write-back, sources/PDF reads, trash, and production `dist/` serving.

For internals / architecture / how to extend, see [`context.md`](./context.md).

## Run

First time:

```sh
cd reader
npm install
cargo fetch --manifest-path rust/Cargo.toml
```

Day-to-day (`vite` + Rust `reader-api` concurrently):

```sh
npm run dev
```

- SPA: `http://localhost:5173/reader/`
- Backend: `http://localhost:5174` (vite proxies `/vault/*`,
  `/reader/data/*`, `/api/*`, `/sources/*` through to it)

Production build:

```sh
npm run build           # rebuilds index, emits dist/
npm run serve           # Rust API serves dist + vault writes in one process
```

Useful one-offs:

```sh
npm run build:index     # rebuild data/index.sqlite after vault changes
npm run build:embeddings # build data/vectors.sqlite (downloads ~2.3 GB BGE-M3)
npm run api             # run only the Rust reader-api backend
npm run test:sql-index  # validate SQLite schema, themes mirror, and FTS
npm run typecheck       # tsc --noEmit
```

### Semantic vectors (hybrid search)

The model-free index build above never touches embeddings. Semantic / hybrid
search needs `data/vectors.sqlite`, built separately and **fully in the
background** — it never blocks the API or UI from starting:

- Trigger from ⚙ Settings → 重建语义向量, or `POST /api/embeddings` (returns
  `202` immediately; poll `GET /api/embeddings/status`).
- On startup the API auto-builds vectors if they're missing **and** the model is
  already cached (a `data/models/.model-ready` sentinel, written after the first
  successful download). Set `READER_AUTO_EMBED=0` to disable boot auto-build.
- Until vectors exist, hybrid search transparently degrades to lexical.

## What it does

**Browsing**

- 6 typed object lists: 论文 / 书 / 章节 / 作者 / 主题 / 笔记
  (Capacities-style colored TypeIcon chips)
- "横切视图 / 主题"：tag index sorted by frequency, click a chip to
  filter that theme across types
- Free-text search across title / author / themes / preview / source
- Rating filter (≥ 0..4 stars)
- 4-column card grid, lazy-paginated past 300 entries

**Reading**

- Click a card → opens in the current tab as a `DocView` (chapters rail
  for books / 3-pane layout / markdown rendered with `[[wikilink]]`
  resolution / property panel on the right)
- Wikilinks navigate within the current tab (history pushed)
- "回到本书" jump on chapter pages

**Editing**

- Frontmatter is always editable in `PropertyPanel`: rating ★ picker,
  year, author, source, DOI, topic, themes chips (add / remove)
- Note bodies edit through a **CodeMirror 6 Markdown editor** with a
  Ulysses-style theme: monoline serif/sans-serif, muted markup, no
  preview pane, no toolbar
- **LLM-generated body** (paper/book/author/topic/chapter) is read-only
  by default. Toggle "允许编辑 LLM 生成的正文" in ⚙ Settings to make all
  entries editable through the same editor surface
- Auto-save debounced 1.5 s; `Cmd+S` flushes immediately; switching tabs
  or closing flushes; `beforeunload` guards unsaved changes

**Notes**

- Personal notes live in `vault/notes/*.md`, the only directory in vault
  whose contents are human-written (vs LLM-generated analyses)
- Two modes via one mechanism — frontmatter `annotates: <vault path>`
  field. With it, the note is an **annotation** on that target and shows
  up in the target's "我的批注 (N)" list. Without it, the note is a free
  **idea note**. Same file shape, same UI; promotion is just adding the
  field
- "+ 新建批注" button on any non-note entry → POSTs a pre-filled draft to
  `vault/notes/<slug>-note-<rand>.md`, opens it in a new tab
- Sidebar "+ 新建 note" → POSTs a standalone idea note
- `⋯` menu in a note's header → 移到回收站, soft-delete to
  `vault/notes/.trash/<base>.<ISO ts>.md` (timestamped to never collide).
  Visit "回收站" in sidebar to restore or purge

**Tabs**

- Top tab bar holds a heterogeneous list of tabs. Each tab has its own
  back/forward history (Cmd+[, Cmd+])
- Tabs come in 4 kinds: `list` (a type), `doc` (an entry),
  `themes` (the index), `trash`
- Click a card or sidebar item → navigates in the current tab.
  Cmd / Ctrl + click → opens in a new tab
- Pin: 📌 toggle on active tab. Pinned tabs sort left, hide × button.
  Drag tabs to reorder (pinned and unpinned cannot swap regions)
- Middle-click or × to close; last tab is unclosable

**Settings (⚙ in sidebar)**

- Editor font: 苹方 / 宋体 / 等宽 (live preview)
- Editor font size 14 / 15 / 16 / 17 / 18 px
- Line height 1.60 / 1.78 / 1.90
- Allow editing LLM-generated body
- All settings hot-swap into CodeMirror via `Compartment.reconfigure`
  (caret / history / selection preserved)

**Paper / book actions**

- "复制引用" → markdown-style citation to clipboard:
  `Author (year). *Title*. Source. https://doi.org/DOI`
- "打开 PDF" → `window.open('/sources/<pdf_slug>.pdf')`. Button only
  appears when build-index found a matching PDF
  (currently 514 / 12539 entries)

## Where files live

| Path | What |
|---|---|
| `src/main.tsx` + `src/app.tsx` | Top-level wiring (tab state, indexes) |
| `src/components/` | All UI components (one per file, see context.md) |
| `src/icons/` | (empty by design — icons come from `~icons/ph/*` virtual modules) |
| `src/types.ts` | `Entry`, `EntryType`, `Tab`, `TabContent` shapes |
| `src/api.ts` | All fetch helpers (GET/PUT/POST/DELETE + trash) |
| `src/frontmatter.ts` | yaml-based parse / serialize |
| `src/wiki.ts` | `[[wikilink]]` resolver |
| `src/settings.ts` | Settings type + persistence |
| `scripts/test-sql-index.mjs` | Validates SQLite schema, theme rows, and FTS smoke search |
| `rust/reader-index` | CLI that walks `vault/` and emits `data/index.sqlite` |
| `rust/reader-core` | Reusable Rust core: SQLite index build/read, path safety, vault/trash operations |
| `rust/reader-api` | Axum HTTP adapter around `reader-core`; future Tauri commands can reuse core |
| `data/index.sqlite` | Generated; read by `/api/index` on app boot |

## Roadmap (not built)

- Cmd+K global search palette
- Daily Notes (date-named auto-created notes)
- `[[` autocomplete in the editor
- Focus mode / typewriter scrolling toggles
- Theme as first-class object (`vault/themes/<slug>.md` with description page)
- Auto-rebuild `data/index.sqlite` on vault changes (file watcher)
- Real list virtualization for 12k+ cards
- Bibtex / CSL citation export formats
- MCP server exposing vault to AI tools
- Tauri shell for native window
