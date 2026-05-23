# marple-native — Design

- **Date:** 2026-05-23
- **Status:** Approved (brainstorming) → ready for implementation plan
- **Topic:** A native macOS (Swift + Rust) reader/browser over the qua vault

## 1. Vision & positioning

**marple-native is a knowledge-aware native macOS reader — "a high-level
file explorer" over the qua vault.** Its job is *find / browse / read /
navigate / manage files*. It deliberately **does not edit body text**:
when the user wants to write, the app hands the `.md` file off to their
real editor (Ulysses / iA Writer / Obsidian / BBEdit / VS Code …) and a
file watcher refreshes the UI when the external editor saves.

This is a re-positioning of the existing web app (Vite + Preact +
CodeMirror over `reader-api`). The single hardest component of the current
stack — an in-app Markdown editor — is removed. With editing outsourced,
the experience-critical surface becomes **browsing 12k+ typed cards** and
**reading rendered Markdown**, both of which are native strengths. That is
exactly where the rewrite spends its effort.

Scope: **macOS-only.** No iPad/iOS target (explicitly out of scope), so we
do not design for cross-Apple-platform abstraction.

### Why native (motivations, in priority order)

1. 编辑/滚动手感 + 12k 卡片列表性能 — the webview UI cannot deliver native
   scroll feel or free list virtualization; only a native UI fixes this.
2. 原生外壳 / 系统集成 — real native window, menus, startup speed, Quick
   Look, drag & drop, Services, "open in…".
3. 想学 Swift / 好玩 — the rewrite has intrinsic learning value; effort is
   spent on the native UI layer, not on re-porting backend logic.

## 2. Goals & non-goals

**Goals**
- Native SwiftUI/AppKit macOS app: snappy typed browsing, instant search
  (lexical + later hybrid/semantic), beautiful native Markdown reading,
  cross-references (wikilinks, themes), context panels.
- Reuse the existing Rust `reader-core` (SQLite index, FTS, BGE-M3
  vectors, path safety, vault read/write, trash) — do **not** re-implement
  the search/embedding backend.
- In-app writes limited to **metadata + file management** (see §6).
- Outsource body editing to an external editor + auto-refresh on save.

**Non-goals**
- No in-app text editor (no CodeMirror replacement, no TextKit editor).
- No iPad/iOS, no Windows/Linux native target.
- No re-implementation of the embedding pipeline in Swift.
- Not a Tauri shell (rejected: keeps the UI in a webview, fails goal #1).

### Carried-over hard guarantees (from `context.md`)

- **Vault is the source of truth, not app state.** All edits round-trip to
  disk; reload restores everything. Local persistence holds only ephemera
  (open tabs, panel widths, settings).
- **LLM-generated vs human-written content stay separable.** Everything in
  `vault/notes/` is human; everything else is generated.
- **Git is the backup / sync / undo layer.** Soft-delete moves files to
  `.trash/`; no in-app permanent undo beyond `git checkout`.

## 3. Architecture

```
marple.app (Swift, macOS)
├─ UI layer (SwiftUI shell + AppKit where needed)
│   Sidebar      6 typed lists + 主题 + 回收站 + ⚙ 设置
│   TabBar       heterogeneous tabs (list/doc/themes/trash),
│                per-tab back/forward history, pin, drag-reorder
│   ListView     native card grid, virtualized for 12k entries
│   DocView      native Markdown reader (swift-markdown → native views)
│                + right panel (目录 / 信息 / 统计)
│   PropertyPanel  metadata editing (评分 / 主题 chips / frontmatter)
│
├─ AppModel (@Observable)   tabs, open indexes, settings
│
└─ VaultClient (protocol)   the ONLY data in/out boundary
        │
   ┌────┴──────────────────────────── chosen: B2 sidecar (see §4)
   ▼
reader-core (existing Rust)
   SQLite index · FTS · BGE-M3 vectors · path safety · vault r/w · trash
        ↕
   <workspace>/vault/**, .marple/index.sqlite, .marple/vectors.sqlite

External edit:  open .md (system default / configured editor app)
File watcher:   FSEvents on vault/** → invalidate + refresh affected entry
```

## 4. Backend integration — `VaultClient` boundary

`VaultClient` is the **single data boundary**. All UI/app code depends only
on this protocol plus Swift-side DTOs — never on a transport.

**Chosen for v1: B2 — Sidecar HTTP.** Bundle the existing `reader-api`
release binary as a child process; Swift talks to it over `localhost` via
`URLSession`. The backend ships unchanged; localhost latency is irrelevant
at 12k scale. The web version can coexist.

**Migration path: B1 — In-process FFI (UniFFI).** Later, a thin
`reader-ffi` crate exposes `reader-core` via UniFFI; `FFIVaultClient`
replaces `HTTPVaultClient`. True single-process app, no localhost/port,
cleanest for distribution/notarization.

**Why B2→B1 is a cheap drop-in (boundary discipline — MUST follow):**

1. **UI/app code imports nothing transport-specific** — only `VaultClient`
   + Swift DTOs.
2. **`VaultClient` methods are `async` and throw `VaultError` from day
   one.** Both URLSession and UniFFI async fit this shape.
3. **DTOs are defined independently of the wire.** `HTTPVaultClient`
   decodes JSON into them; `FFIVaultClient` maps UniFFI-generated types
   into them.

What the migration still costs (unavoidable, B1-intrinsic — you'd pay it
even starting at B1): building `reader-ffi` + UniFFI bindings + the
cargo→xcframework build pipeline, plus ensuring `reader-core` FFI calls are
dispatched off the main thread with sound SQLite-handle threading. The only
*wasted* B2 work is the sidecar lifecycle glue (spawn / free-port / bundle
/ codesign the helper) — small, and it buys a working app much sooner.

### `VaultClient` surface (initial)

```
protocol VaultClient {
  // reads
  func index() async throws -> [Entry]                 // all entries on boot
  func entry(id: EntryID) async throws -> EntryDetail   // body + frontmatter
  func search(_ q: SearchQuery) async throws -> [SearchHit]  // lexical now; hybrid in P5
  func themes() async throws -> [Theme]
  func trash() async throws -> [TrashItem]
  // writes (metadata + file mgmt — see §6)
  func writeFrontmatter(id: EntryID, _ fm: Frontmatter) async throws
  func createNote(_ draft: NoteDraft) async throws -> EntryID
  func moveToTrash(id: EntryID) async throws
  func restore(_ item: TrashItem) async throws
  func purge(_ item: TrashItem) async throws
  // host integration
  func openPDF(id: EntryID) async throws
  func openInEditor(id: EntryID) async throws           // open .md externally
}
```

These map onto existing `reader-api` endpoints (`/api/index`, `/api/*`,
`/api/open-pdf`, vault write-back, trash). `openInEditor` is a new
sibling of the existing `open-pdf` shell-out (`open` / `open -a <app>`).

## 5. Reading view (the experience core)

Chosen: **A — native rendering.**

- Parse with **swift-markdown** (Apple's cmark-gfm wrapper) to a `Document`
  AST.
- A custom `MarkupVisitor` renders the AST into **native views** (headings,
  paragraphs, lists, blockquotes, code blocks, the rare table/image).
- **`[[wikilink]]`** is not standard Markdown: preprocess into a custom
  inline node, resolve targets via `VaultClient`, render as a tappable
  element. Click → **navigate within the current tab** (push history),
  matching the web app's wikilink behavior.
- **Scroll-spy**: track the visible heading (anchors / scroll position) to
  drive the right panel's 本页 outline; clicking an outline entry scrolls
  to it.
- Reading typography settings (字体 苹方/宋体/等宽, 字号, 行高) move from
  "editor settings" to **reading settings**, applied live to the renderer.

## 6. Write surface (metadata + file management)

Body text is **never** edited in-app. Everything else stays:

- **Metadata (Finder-style "tagging"):** rating ★, year, author, source,
  DOI, topic, themes chips (add/remove) — edited in `PropertyPanel`,
  written via `writeFrontmatter`. Writes are **immediate and explicit** (no
  debounced autosave, no Cmd+S, no `beforeunload` guard — those were
  text-editor concerns and are dropped).
- **File management:** 新建 note / 新建批注 (frontmatter `annotates:` field
  toggles annotation vs idea note, as today), 移到回收站 (soft-delete to
  `vault/notes/.trash/<base>.<ISO ts>.md`), restore / purge from 回收站.

## 7. External-editor handoff + file watcher

- DocView shows a **"用外部编辑器打开"** action → `openInEditor` → shells
  `open` (system default) or `open -a <configured app>` (Settings).
- An **FSEvents watcher** on `vault/**` detects external saves and:
  - reloads the affected entry's body/frontmatter if open,
  - marks the index stale for that file (and, in P5+, can trigger an
    incremental `reader-index` rebuild — currently a roadmap item).
- The "允许编辑 LLM 生成的正文" toggle is repurposed: it gates whether the
  external-open action appears on LLM-generated docs (default: allowed).

## 8. Components (Swift side)

| Unit | Responsibility | Depends on |
|---|---|---|
| `AppModel` | tab state, open indexes, settings (mirrors `app.tsx`) | `VaultClient` |
| `Sidebar` | 6 types + 主题 + 回收站 + ⚙ | `AppModel` |
| `TabBar` | tabs (list/doc/themes/trash), history, pin, drag | `AppModel` |
| `ListView` | typed card grid, virtualized; sort/filter/rating/theme | `AppModel`, list-sort logic |
| `DocView` | native Markdown reader + right panel | `VaultClient`, renderer |
| `MarkdownRenderer` | swift-markdown AST → native views, wikilinks | `VaultClient` (link resolve) |
| `PropertyPanel` | metadata edit → `writeFrontmatter` | `VaultClient` |
| `ThemesView` | tag index, click chip to cross-cut filter | `AppModel` |
| `TrashView` | restore / purge | `VaultClient` |
| `SettingsView` | reading typography, external editor app, LLM-open toggle | settings store |
| `HTTPVaultClient` | concrete backend (sidecar) | `reader-api` |
| `SidecarProcess` | spawn/port/lifecycle of bundled `reader-api` | — |
| `VaultWatcher` | FSEvents → refresh | `AppModel` |

**Pure logic to port (low risk):** list sort + extra filters
(`src/list-sort.ts`), doc outline (`doc-outline.ts`), doc stats
(`doc-stats.ts`), wikilink resolution (`wiki.ts`). With the sidecar these
*may* stay Rust-side; cheap ones (outline, stats) can compute Swift-side
from loaded text. Decide per-unit during implementation.

## 9. Error handling

- All `VaultClient` calls throw `VaultError` (cases: `.network`,
  `.notFound`, `.decode`, `.backendUnavailable`, `.write(reason)`).
- Sidecar unavailable (crashed / not yet up) surfaces a non-blocking
  banner with a retry; reads degrade gracefully (show last index if cached).
- Hybrid/semantic search **transparently degrades to lexical** when
  `vectors.sqlite` is absent (existing backend behavior preserved).
- Writes are confirmed against the backend response; on failure the UI
  reverts the optimistic metadata change and shows the error.

## 10. Testing strategy

- **`VaultClient` contract tests** against a stub implementation — every UI
  flow is testable without a running backend.
- **`HTTPVaultClient` integration tests** against a real `reader-api` on a
  scratch vault (mirrors `scripts/test-sql-index.mjs` intent).
- **Renderer snapshot tests** for representative Markdown (headings, lists,
  code, blockquote, wikilink, table) — guards reading fidelity.
- **Pure-logic unit tests** for ported list-sort / outline / stats (port
  the existing Vitest cases).
- Manual: launch the app on the real 12k vault, verify scroll/list feel,
  search latency, external-edit→refresh loop end to end.

## 11. Phasing (walking skeleton first)

- **P1 — Foundation / walking skeleton.** Sidebar + 论文 list (native card
  grid) → open a card → native Markdown reader with wikilink navigation →
  "用外部编辑器打开" + file-watcher refresh. Stand up `VaultClient` +
  `HTTPVaultClient` + `SidecarProcess`. Proves the experience-critical
  reading loop and the backend boundary in one thin end-to-end slice.
- **P2 — Browse.** Lexical search; sort / filter / rating; all 6 types;
  主题 cross-cut view.
- **P3 — Read context + metadata.** Right panel (目录 / 信息 / 统计);
  `PropertyPanel` metadata write-back; tabs + history + pin + reorder.
- **P4 — File management.** 新建 note / 批注; 回收站 restore / purge.
- **P5 — Search depth + polish.** Hybrid/semantic search + embedding status
  / trigger; Settings polish; Cmd+K command palette.

(Optional later: B1 UniFFI migration; incremental index rebuild on watch.)

## 12. Risks & open questions

- **Native Markdown rendering breadth** — table/image/code fidelity in
  custom views is the main rendering risk; P1 validates the common cases
  first. (Mitigation: the AST visitor can fall back to a styled raw block
  for unsupported node types.)
- **12k-card scroll perf** — `LazyVGrid` may need `NSCollectionView`
  (cell reuse) for true smoothness; decide in P1/P2 with the real vault.
- **Sidecar packaging** — spawning, free-port selection, bundling, and
  codesigning the helper binary; throwaway when migrating to B1.
- **Workspace selection** — how the app learns `workspaceRoot`
  (`marple.config.json` / `VAULT_ROOT` today); native app likely a
  first-run picker persisted to app prefs. (Settle in P1.)
