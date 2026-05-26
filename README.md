# marple

> I like to pass unnoticed, which is why I hope that I am not deprived of old age. I aspire to Miss Marple's persona: to be exactly as I am, decrepit nature yet supernature in one, equally alert on the damp ground and in the turbulent air. ——Gillian Rose

A native macOS reader/browser over the qua vault — typed-object sidebar,
swift-markdown reader, frontmatter inspector, tabs/history, trash, and
in-process Qwen3-Embedding semantic search.

**Stack:** Swift 6 (SwiftUI + AppKit shell) · MarpleKit (pure-Swift index + search) ·
MLXEmbedders (Qwen3-Embedding for semantic search) · GRDB + SQLite FTS5 ·
swift-markdown.

The full app and library live in [`apple/`](./apple/). See
[`apple/ARCHITECTURE.md`](./apple/ARCHITECTURE.md) for the structure map.

## Run

```sh
cd apple
swift build
swift run Marple
```

Tests (this Mac has Command Line Tools, not full Xcode — swift-testing needs
the explicit framework path):

```sh
cd apple
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

Build a proper `.app` bundle (so the Dock icon shows up):

```sh
cd apple
./build-app.sh
open Marple.app
```

First launch asks you to pick the vault workspace (the directory that
contains your `.md` library). The choice is persisted in
`@AppStorage("marple.workspaceRoot")`.

## Legacy

The earlier Vite + Preact web SPA and Tauri shell, plus the Rust
`reader-api` / `reader-core` sidecar, are archived under [`legacy/`](./legacy/).
They are no longer maintained; the Swift port covers all of their
runtime responsibilities (indexer, search, semantic search included).
