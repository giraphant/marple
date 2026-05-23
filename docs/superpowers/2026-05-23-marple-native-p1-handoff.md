# marple-native — Session Handoff / Work Log (P1 done)

**Date:** 2026-05-23 · **Branch:** `main` (work committed + pushed to
`origin/main`, github.com/giraphant/marple) · **HEAD at handoff:** `683359a`

This log lets a fresh session continue without re-reading the whole prior
conversation. Read this + the spec + the plan and you're caught up.

## What this is

A **native macOS SwiftUI reader** ("a knowledge-aware Finder") over the qua
vault, living in `apple/` as a Swift Package. It reuses the existing Rust
`reader-api` as a **sidecar** (no web changes). Editing is outsourced to an
external editor; the app is read + browse + navigate + open-externally + watch.

- **Design spec:** `docs/superpowers/specs/2026-05-23-marple-native-reader-design.md`
- **P1 plan:** `docs/superpowers/plans/2026-05-23-marple-native-p1-walking-skeleton.md`
  (includes an Environment Addendum about the CLT-only toolchain)

## Status: P1 complete, GUI-validated, shipped

The P1 walking skeleton is done and the user confirmed it works as a demo:
sidebar lists 论文 → click → native Markdown reading view (wrapping text +
tappable wikilinks) → "用外部编辑器打开" → FSEvents refresh on external save.
Reading loop + external-editor open + scroll feel were validated good.

## Architecture (as built)

```
apple/  (Swift Package — swift-tools 6.0, macOS 14)
├── Sources/MarpleKit/   (logic, unit-tested with swift-testing)
│   Entry.swift          Entry + EntryType (raw-preserving, .other fallback)
│   VaultClient.swift    protocol + VaultError + StubVaultClient
│   HTTPVaultClient.swift  /api/index, GET /<vault path>, POST /api/open-in-editor
│   SidecarProcess.swift   SidecarLaunch (freePort/args/env/baseURL) + spawn/readiness
│   Frontmatter.swift    split(raw) -> (frontmatter, body)
│   Wikilink.swift       protect/restore/tokenize + WikiResolver
│   MarkdownModel.swift  swift-markdown -> [RenderBlock]
│   VaultWatcher.swift   Coalescer (debounce) + FSEvents watcher
└── Sources/Marple/      (SwiftUI app, validated by build + manual run)
    MarpleApp.swift      @main: sidecar boot, NavigationSplitView, watcher; line-buffered stdout
    AppModel.swift       @Observable @MainActor state hub (+ [marple] stdout logging)
    SidebarView.swift    论文 list (List + selection)
    DocView.swift        reader ScrollView + open-in-editor toolbar + OpenURLAction for wikilinks
    MarkdownBlocksView.swift  BlockView renders [RenderBlock]; attributedInline + WikiURL
```

Data boundary: all UI depends only on `VaultClient` + DTOs. P1 uses
`HTTPVaultClient` (sidecar). The planned later swap to in-process UniFFI (B1)
is a drop-in behind this protocol.

## Build / run / test (CLT-only — no Xcode → swift-testing, not XCTest)

```sh
cd apple && swift build
# tests need the CLT framework search path (bare `swift test` errors: no module 'Testing'):
cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
# run the app, capturing logs (line-buffered, so [marple] traces stream live):
cd apple && swift run Marple > /tmp/marple-app.log 2>&1
```

Test suite at handoff: **28 passing** in MarpleKit. swift-markdown resolves via
`branch: "main"`.

**Live-debug workflow (key — the controller can't see the GUI):** run the app
backgrounded with stdout → a log file, have the user drive the UI, and tail the
log. `AppModel` prints `[marple] index loaded / open / follow / openInEditor /
watcher reload` and the sidecar prints its boot lines. To stop a run:
`pkill -f "debug/Marple"; pkill -f "release/reader-api"`.

## Sidecar config (how the app finds the vault)

`SidecarProcess` runs `cargo run --release --manifest-path <repo>/rust/Cargo.toml
-p reader-api` with env `MARPLE_ROOT=<repo>` + `PORT=<free>`. reader-api resolves
the vault from `<repo>/marple.config.json` → `workspaceRoot` (currently
`/Users/ramudai/Documents/Learn/bts`, which has `.marple/index.sqlite`, ~15,142
entries / 2,198 论文). Needs a built index there (`npm run build:index` once).

## Bugs found during GUI validation and FIXED (don't regress these)

1. **Empty sidebar** — one vault entry typed `topic-reading-list` (a 7th type
   beyond the modeled six) failed the strict all-or-nothing `[Entry]` decode.
   Fixed: `EntryType` is now `RawRepresentable` with `.other(String)`. (`815f562`
   defined Entry; fix `da2cbf8`.)
2. **Crash on navigation** — `ForEach(openBlocks.indices, id:\.self)` + subscript
   went out of bounds when the observable array shrank. Fixed: iterate an
   enumerated snapshot, never re-subscript the live array. (`c97d157`)
3. **Text not wrapping** — custom `FlowLayout` laid each text token at its
   unconstrained single-line width → paragraphs clipped off the right edge.
   Fixed: replaced with wrapping `Text(AttributedString)`; wikilinks are `.link`
   runs routed via `OpenURLAction` (`marple://wiki/<target>`). (`683359a`)

## Known limitations / deferred (NOT bugs to fix blindly)

- **Reading-view rendering polish** (user said not urgent): inline emphasis
  (bold/italic) is currently flattened to plain text; tables/images aren't
  rendered; blockquotes flatten multi-paragraph structure. → P2.
- **Hardcoded dev paths**: `MarpleApp.swift` hardcodes `repoRoot` and `vaultDir`
  (only runs on this machine). Needs env/first-run picker before another machine.
- **NSTableView "reentrant operation" warning** from the sidebar selection
  binding (currently a warning; "will become an assert" — watch it).
- `IMKCFRunLoopWakeUpReliable` console line is benign (running unbundled via
  `swift run`).
- Sidecar is `cargo run` (dev), not a bundled binary; first launch blocks on a
  release compile and fails as `backendUnavailable` if `cargo` isn't on PATH.

## Conventions (IMPORTANT)

- **Work directly on `main`** (user authorized; no feature branch/worktree).
- **Only stage files you authored under `apple/` (and `docs/`).** The user has
  unrelated in-progress working-tree edits to `index.html`,
  `src/components/DocView.tsx`, `src/components/Sidebar.tsx`,
  `src-tauri/tauri.conf.json` — never stage/commit/revert those.
- Never break the web app (nothing committed outside `apple/` + `docs/`).

## Next: P2

Per the spec's phasing, P2 = the typed **6-category sidebar**
(论文/书/章节/作者/主题/笔记) + **lexical search** (`GET /api/search`) +
**sort/filter** (port `src/list-sort.ts`) + **主题 cross-cut view**. This is
what the user noticed missing ("按不同分类的侧边栏"). Start with brainstorming →
scope → writing-plans, then subagent-driven execution as in P1.
