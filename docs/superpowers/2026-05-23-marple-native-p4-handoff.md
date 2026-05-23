# marple-native P4 — File management (work log / handoff)

- **Date:** 2026-05-23
- **Status:** IMPLEMENTED + GUI-validated by user ("OK") + committed to `main` (NOT pushed).
- **Spec:** `docs/superpowers/specs/2026-05-23-marple-native-p4-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-23-marple-native-p4.md`

## What shipped

P4 completes the write surface beyond metadata: **create note / annotation,
soft-delete to trash, and a 回收站 (restore / purge) view.** The Rust
`reader-api` already exposed every endpoint, so all work was Swift-side.

**MarpleKit (pure, TDD):**
- `TrashItem.swift` — DTO decoded from `GET /api/trash` (keys `name`,
  `originalBase`, `ts`, `mtime`, `size`; camelCase verified against
  `reader-core`).
- `NoteBuilder.swift` — pure `NoteDraft` builder for idea notes
  (`vault/notes/<date>-idea-<stamp>.md`) and annotations
  (`<slug>-note-<stamp>.md`, with `annotates: <target>`). Ports the web app's
  `newIdeaDraft` / `newAnnotationDraft` / `slugify`; `today`/`stamp` injected for
  deterministic tests. Title rendered via `FrontmatterPatch.yamlScalar`
  (quote-only-when-needed; equivalent valid YAML, not byte-identical to the
  web's always-quote).
- `VaultClient` protocol + `HTTPVaultClient` gained 5 methods: `createNote`
  (POST), `moveToTrash` (DELETE → trash path), `listTrash` (GET), `restoreTrash`
  (POST), `purgeTrash` (DELETE). `StubVaultClient` got assertable
  `CreateLog`/`TrashStore`.
- `Pane.trash` added (`entriesForPane(.trash)` → `[]`, the `.themesIndex`
  non-list precedent).

**Marple executable (build-verified + GUI):**
- `AppModel`: `trashItems` state (loaded at boot + on entering the pane + after
  mutations); `newIdeaNote` / `newAnnotation(for:)` / `newAnnotationForOpenDoc`;
  `moveToTrash` / `restoreTrash` / `purgeTrash` / `loadTrash`.
- `TrashView.swift` — lists trashed items (original name / ts / size), per-row
  恢复 + 彻底删除 (with a confirmation dialog), empty state, refresh.
- `SidebarView` — 回收站 row with live badge; 新建笔记 bottom button.
- `RootView` — content switch routes `.trash` → `TrashView`.
- `EntryListView` — context menu gains 新建批注 + 移到回收站.
- `DocView` — toolbar `+` (new idea note) + 新建批注 (annotate open doc).
- `TabCommands` — ⌘N → 新建笔记 (`CommandGroup(replacing: .newItem)`).

## Key decisions (freshness)

- **Optimistic create**: append a known `Entry` built from the draft → reveal in
  the reader → hand off to the external editor (it's a reader; the empty note is
  edited outside).
- **Optimistic trash**: remove the row from `entries`; if the active tab showed
  it, clear the doc. Background tabs/history pointing at a trashed doc degrade to
  the existing "load failed" placeholder on revisit (not pruned) — accepted.
- **Restore reloads the index** (the one exception): a restored file can't be
  cheaply reconstructed into an `Entry`, so `restoreTrash` calls `loadIndex()`.
  Rare action; acceptable.
- **Purge** just drops the item from `trashItems`.
- The **watcher → full-index refresh** backlog item stays DEFERRED (external
  add/delete still leaves counts stale until relaunch).

## Verification

- `swift build` clean.
- `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
  → **120 tests in 23 suites pass** (P3b's 104 + 16 new: TrashItem ×2,
  NoteBuilder ×5, stub ×3, HTTP ×5, Browse ×1).
- App boots on the real 15,142-entry vault; sidecar route list confirms the
  create/trash endpoints. Only the carried benign NSTableView reentrancy warning.
- **GUI-validated by user 2026-05-23** ("OK").

## Commits (on `main`, not pushed)

`feat(native): TrashItem DTO` → `NoteBuilder` → `VaultClient trash + create
(stub)` → `HTTPVaultClient create + trash endpoints` → `AppModel trash
state + actions` → `回收站 pane + view + soft-delete` → `AppModel new
note/annotation actions` → `new note/annotation UI`, plus the spec and plan
docs. P2–P4 remain **committed-not-pushed** on `main`.

## Next (P5 per the master plan)

Search depth + polish: hybrid/semantic search + embedding status/trigger,
Settings (reading typography, external-editor app, LLM-open toggle), ⌘K command
palette. Plus standing backlog: browse-state persistence across launches, and
the watcher-index-refresh.
