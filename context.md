# reader/ Context

## Purpose

Lightweight card-style reader over the qua vault. Designed for read-heavy
browsing (Scrivener corkboard + Capacities typed entities). Built outside
Obsidian because Obsidian's eager indexing is sluggish at ~2400 entries.

## Key Components

- `scripts/build-index.mjs` — Node, no deps. Walks `../vault/`, parses
  frontmatter, emits `data/index.json` (one row per md, with `preview`
  computed from the first body paragraph).
- `serve.mjs` — ~50-line Node static server rooted at the worktree, so the
  SPA can fetch `vault/**/*.md` with absolute paths.
- `index.html` — single-file Preact app. CDN-loaded
  (Preact / htm / marked / Tailwind), no bundler.
- `data/index.json` — generated; ~1–2 MB; loaded once on app boot.

## Recent Changes

- 2026-05-11: v0.2.1 — Obsidian `[[wikilink]]` resolution in rendered
  markdown. Client-side `wikiIndex` keys each entry under: vault-relative
  path without ext, bare basename, `<book>/<chapter>` form, and book-slug
  alone for overviews; case-insensitive. Pre-processes body before
  `marked.parse`, replaces resolved targets with `<a data-wiki="…">` and
  unresolved with a struck-through `<span class="wiki-broken">`. Article
  container delegates clicks on `[data-wiki]` to the drawer navigator.
- 2026-05-11: v0.2.0 — Capacities-style "typed object" surface.
  - Per-type dashboard (count, avg rating, top themes, top-rated) above grid.
  - Right-side property panel in the drawer (rating / year / author / DOI /
    source / topic / chapters_analyzed) with clickable theme chips.
  - Derived backlinks (no file writes):
    - author-profile → "作品" list (papers + books whose `author` matches).
    - paper / book → "同作者其他" (other works) + "同主题相似" (papers
      sharing ≥2 themes, ranked by overlap × rating).
    - book → existing chapter rail.
  - Theme filter state — clicking any theme chip anywhere filters the
    current type view; cleared on type switch.
- 2026-05-11: v0.1.0 initial MVP. 5 type tabs, search, rating filter,
  side-drawer reader, lazy pagination.

## Dependencies

- Internal: `vault/**/*.md` with consistent YAML frontmatter
  (`type`, `title`, `author`, `year`, `rating`, `themes`, …).
- External (CDN at runtime): preact@10, htm@3, marked@12, tailwindcss play.
- Runtime: Node ≥ 18 (built-in `fs/promises`, `http`).

## Known Issues / Tech Debt

- Frontmatter parser is hand-rolled; doesn't handle nested maps, multi-line
  strings, or YAML anchors. Sized to current vault frontmatter shapes only.
- 2000+ cards rendered all at once — fine due to `content-visibility: auto`,
  but a real virtualization (e.g. `@tanstack/virtual` or windowed list)
  would scale better.
- No file watcher — re-run `build-index.mjs` after vault changes.
- No `[[wiki-link]]` resolution inside rendered markdown yet.

## API Surface

- `npm run build` → regenerate index
- `npm run serve` → start server on `PORT` (default 5174)
- `npm run dev`   → both
