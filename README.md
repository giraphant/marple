# qua reader (MVP)

Card-style reader over the qua vault. Read-mostly. No build step on the
frontend — single HTML file loads Preact + marked + Tailwind from CDN.

## Layout

```
reader/
  index.html              # the SPA (Preact via esm.sh, Tailwind via Play CDN)
  serve.mjs               # tiny static server, rooted at the worktree
  scripts/
    build-index.mjs       # scans ../vault/, writes data/index.json
  data/
    index.json            # generated; one row per md file with frontmatter
```

## Run

From the worktree root:

```sh
node reader/scripts/build-index.mjs   # rebuilds the index
node reader/serve.mjs                 # serves at http://localhost:5174/reader/
```

Or combined:

```sh
cd reader && npm run dev
```

The server is rooted at the worktree so the SPA can fetch `vault/**/*.md`
directly when you click a card.

## What's in v0.1

- 5 tabs by `type`: paper / book / chapter / author / topic
- Free-text search across title / author / themes / preview
- Rating filter (≥ N stars)
- Click card → side-drawer reader with rendered markdown, Esc to close
- Lazy 500-at-a-time pagination when no query
- `content-visibility: auto` on cards so 2000+ stays scrollable

## Roadmap (not built yet)

- Pin / multi-card view (Scrivener corkboard)
- Theme facets and year slider
- Inter-card link graph from `[[wiki]]` references
- Author → works back-reference
- Tauri shell for native window + filesystem watcher
