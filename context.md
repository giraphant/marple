# reader/ Context

## Purpose

Lightweight card-style reader over the qua vault. Designed for read-heavy
browsing with editable Capacities-style typed properties. Built outside
Obsidian because Obsidian's eager indexing is sluggish at ~12k entries.

## Key Components

- `src/main.tsx` — Vite entry, renders `<App/>` into `#app`.
- `src/app.tsx` — top-level container: tab nav, search/filter, dashboard,
  reader drawer wiring, in-memory entry list with optimistic updates on
  edit / create / delete. Owns `Settings` state and persists to localStorage.
- `src/components/` — `Card`, `MiniRow`, `Dashboard`, `Reader`,
  `PropertyPanel`, `NoteEditor` (CodeMirror 6 + Ulysses theme),
  `SettingsPanel` (all `.tsx`, Preact + JSX).
- `src/settings.ts` — Settings type, load/save helpers (localStorage).
- `src/frontmatter.ts` — frontmatter parse / serialize using the `yaml`
  package; preserves inline arrays and empty values so write-backs leave
  small, intentional diffs.
- `src/api.ts` — GET/PUT helpers for vault md files; `patchFrontmatter`
  read-modify-write convenience for property edits.
- `src/wiki.ts` — `[[wikilink]]` index, link resolution, author splitter.
- `src/types.ts` — `Entry` shape and the canonical type registry.
- `scripts/build-index.mjs` — Node, uses `yaml` package. Walks `../vault/`,
  emits `data/index.json` (one row per md, with `preview` computed from the
  first body paragraph).
- `serve.mjs` — Node static server rooted at the worktree (GET) plus a
  `PUT /vault/**/*.md` endpoint for write-back. Path-traversal hardened,
  `.md`-only, requires existing target, requires `---` fence in body,
  atomic via temp file + rename.
- `data/index.json` — generated; ~12k entries, ~5 MB; loaded once on boot.
- `vite.config.ts` — Vite dev server proxies `/vault` and `/reader/data`
  to `serve.mjs` on 5174, so the SPA uses the same absolute paths in dev
  and prod.

## Recent Changes

- 2026-05-14: v0.5.0 — Markdown editor, auto-save, soft-delete, settings.
  - **CodeMirror 6 + lang-markdown** as the editor surface, with a custom
    Ulysses-style HighlightStyle: # ## > * markers stay visible but muted,
    the content they wrap is what stands out. Serif font, line-height 1.78,
    no toolbar, no preview pane. `[[wikilink]]` autocomplete is not yet
    wired but the editor framework is in place.
  - **Auto-save**: every edit debounces 1.5s then PUTs back. Header shows
    `未保存…` → `保存中…` → `已保存`. Cmd+S flushes immediately. Switching
    entries or closing the drawer also flushes pending writes.
    `beforeunload` guard prevents losing bytes on hot reload.
  - **Settings panel**: gear icon top-right. Single toggle for now —
    "允许编辑 LLM 生成的正文". Default off (note-only edit); when on, all
    types load into the same editor. Persisted to localStorage.
  - **Soft delete**: `⋯` menu in drawer header (only for notes). Confirm
    dialog moves the file to `vault/notes/.trash/<base>.<ISO-ts>.md`.
    ISO timestamp prevents successive same-name deletions from
    overwriting each other (verified with double-delete test).
    `build-index` already skips dot-prefixed dirs so `.trash` is
    automatically off the index.
  - **`DELETE /vault/notes/**/*.md`**: serve.mjs endpoint with same
    defenses as POST — must resolve under `vault/notes/`, must be `.md`,
    target must exist; returns 200 + `{ok, trash: <new-path>}`.
  - **Bundle**: 169KB → 695KB minified / 55KB → 236KB gzip due to
    CodeMirror. Acceptable for a desktop SPA, but worth lazy-loading the
    editor module in a follow-up if perceived load time becomes an issue.

- 2026-05-14: v0.4.0 — personal notes + annotation system.
  - **`note` as a first-class type**: 6 tabs now (paper / book / chapter /
    author / topic / note). Notes live in `vault/notes/*.md` with
    `type: note`. README in that dir documents the schema. LLM-generated
    analyses (papers/books/authors/topics) and human-written notes are
    cleanly separated by directory + type.
  - **Annotation via `annotates:` field**: a note with
    `annotates: <vault-relative path>` becomes a back-linked annotation on
    that target; without it, the note is a free-standing idea. No directory
    split, no second file type — same mechanism for both.
  - **Reverse-link UI**: opening any non-note entry shows a "我的批注 (N)"
    section in the right panel listing notes that annotate it. Opening a
    note shows a "批注于 …" chip at the top of the panel that navigates to
    the target.
  - **"+ 新建批注" button**: in the property panel of any non-note entry.
    Generates a draft note with pre-filled `type/title/annotates/created`
    frontmatter, POSTs it to `vault/notes/<slug>-note-<rand>.md`, then
    opens the newly created note in the reader. Local entries list is
    updated optimistically so the new note immediately shows up in the
    note tab and as a backlink.
  - **`POST /vault/notes/**/*.md`**: serve.mjs gained a creation endpoint
    with layered defenses — must resolve under `vault/notes/`, must be
    `.md`, target must not exist (409 otherwise), body must start with
    `---` fence, 5 MB cap, atomic temp + rename, returns 201 with
    `{ok,bytes,mtime,path}`.
  - Index gained `annotates` and `created` columns; `Entry` type updated.

- 2026-05-13: v0.3.0 — editable properties + Vite/TS stack.
  - **Stack**: migrated from CDN single-file to Vite 5 + TypeScript +
    Preact, real `package.json` deps. Tailwind via PostCSS (no Play CDN).
    `npm run dev` runs `vite` + `serve.mjs` concurrently; `npm run build`
    emits a static bundle to `dist/`.
  - **YAML**: frontmatter parse/serialize moved off the hand-rolled
    matcher onto the `yaml` package. Read accepts both `★★★` and `3`
    style ratings; write normalizes to `★`. Inline arrays of scalars stay
    flow (`themes: [a, b, c]`); empty values stay bare (`year:` not
    `year: null`); `flowCollectionPadding: false` keeps brackets tight.
  - **Edit**: `PropertyPanel` rows are now click-to-edit — rating (1–5★
    picker + clear), year/author/source/topic/doi (inline text input,
    Enter to commit, Esc to cancel, blur to commit), themes (chip add /
    remove with comma-separated multi-add). Each save round-trips through
    `patchFrontmatter` and updates the in-memory entry list optimistically,
    so siblings/similar/backlinks reflect the change immediately.
  - **Server write-back**: `serve.mjs` gained `PUT /vault/**/*.md` with
    layered defenses — must resolve inside `vault/`, must be `.md`, file
    must already exist, body must start with `---` fence, 5 MB cap,
    atomic temp-file + rename, JSON `{ok,bytes,mtime}` response.
  - **Type aliases**: `author: 'author-profile'` added to the canonical
    map; previously 7 such files were dropped silently.
- 2026-05-11: v0.2.1 — Obsidian `[[wikilink]]` resolution in rendered
  markdown. Now lives in `src/wiki.ts`.
- 2026-05-11: v0.2.0 — Capacities-style typed-object surface
  (per-type dashboard, property panel, derived backlinks, theme filter).
- 2026-05-11: v0.1.0 initial MVP. 5 type tabs, search, rating filter,
  side-drawer reader, lazy pagination.

## Dependencies

- Internal: `vault/**/*.md` with consistent YAML frontmatter
  (`type`, `title`, `author`, `year`, `rating`, `themes`, …).
- Runtime: Node ≥ 18.
- Production deps: `preact`, `marked`, `htm` (legacy, unused by new code),
  `yaml`.
- Dev deps: `vite`, `@preact/preset-vite`, `typescript`, `tailwindcss`,
  `postcss`, `autoprefixer`, `concurrently`, `@types/node`.

## Known Issues / Tech Debt

- CodeMirror 6 ships in the main bundle (~200KB gzip of the total 236KB).
  Lazy-loading the editor module when the drawer first opens an editable
  entry would cut initial load on the cards view.
- Wikilink autocomplete in the editor isn't wired yet — typing `[[`
  inside a note doesn't pop a suggestion list. Framework supports it
  (CodeMirror autocomplete + vault entries as the source).
- Focus mode and typewriter scrolling are not implemented; the
  Compartment hooks in `NoteEditor` are set up for the future toggle.
- Trash recovery / browsing isn't surfaced in the UI; files are visible
  via the filesystem and via `git log` only.
- Write-back loses original double-quote style on string scalars
  (`author: "Anna Harris"` → `author: Anna Harris`). YAML-equivalent and
  unambiguous, but produces incidental diff lines. Fixable by parsing
  through the yaml Document AST instead of a plain object so original
  scalar style can be preserved per node.
- No file watcher — re-run `npm run build:index` after vault changes.
- 12k cards rendered all at once — fine due to `content-visibility: auto`,
  but a real virtualization (e.g. windowed list) would scale better.
- Body content is still read-only — only frontmatter is editable.
  A future iteration could add a CodeMirror panel for body editing with
  `[[` autocompletion. Note body editing is particularly desirable so
  users don't have to open the file in an external editor after creating
  a new annotation.
- POST endpoint is scoped to `vault/notes/` only. Creating new
  paper/book/author entries from the reader isn't supported yet — those
  still come from the quasi processing pipeline.
- Notes have no rating/year/author/source/doi fields by design — the
  property panel's editable rows render as `—`. If a note grows to need
  metadata, the rows are still wired and a `themes` chip editor works.

## API Surface

- `npm run dev`         → vite + serve.mjs concurrently
- `npm run dev:vite`    → vite only (assumes serve.mjs already running)
- `npm run build`       → rebuilds index + emits production bundle
- `npm run build:index` → regenerate `data/index.json`
- `npm run serve`       → start static + PUT server on `PORT` (default 5174)
- `npm run typecheck`   → `tsc --noEmit`
