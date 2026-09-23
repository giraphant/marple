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
make run
```

The bundle is assembled at `~/Library/Caches/marple-dev/Marple.app` — off the
iCloud-synced repo tree, which codesign rejects (QUA-199).

First launch asks you to pick the vault workspace (the directory that
contains your `.md` library). The choice is persisted in
`@AppStorage("marple.workspaceRoot")`.

## Organize tabs from the CLI

With Marple running and its CLI server enabled, `marple-cli tabs list` returns
the current Space's sidebar tree as JSON, including each item's `id`, `kind`,
`title`, document `path`, pinned state, and nested `children`. Use those full
UUIDs in subsequent commands; tab and folder IDs are valid for the running
session and should be fetched again after restarting Marple.

```sh
marple-cli tabs list
marple-cli tabs rename TAB_ID 'Reading notes'
marple-cli tabs rename TAB_ID --reset
marple-cli tabs move TAB_C TAB_A --after TAB_B
marple-cli folders create 'Research' --items TAB_A TAB_B
marple-cli folders create 'Sources' --parent FOLDER_ID --items TAB_C
marple-cli tabs move TAB_A TAB_B --parent FOLDER_ID
marple-cli folders rename FOLDER_ID 'Literature'
marple-cli folders move CHILD_FOLDER_ID --parent PARENT_FOLDER_ID
marple-cli folders move FOLDER_ID --before OTHER_FOLDER_ID
marple-cli tabs move TAB_ID --root
marple-cli folders dissolve FOLDER_ID
```

Each move takes exactly one destination: `--parent FOLDER_ID`, `--root`,
`--before ITEM_ID`, or `--after ITEM_ID`. Before/after uses the anchor's parent
and sidebar section; `--root` appends to the fixed pages section. Moving into
a folder or the fixed section pins tabs, matching sidebar drag-and-drop.
Moving tabs beside a temporary tab makes them temporary. Folders cannot move
into the temporary section. Selected items keep their command-line order;
when a folder and its descendants are selected together, the folder carries
its descendants once.

`folders create --items` accepts both tab and folder IDs and returns
`createdID`. Without `--items` it creates an empty folder. `folders dissolve`
removes the container and promotes its children in place. These are sidebar
folders; document files and their names stay intact. Changes are saved through
the app's normal persistence and can be undone in the app. Invalid requests
leave the entire operation unapplied. App responses use the existing JSON
success/error envelope, and failed commands exit with a nonzero status.

Each folders/tabs write generates a UUID `requestID`, returned in its JSON
response, including transport errors. If the response is lost, repeat the
**same command and arguments** with that key:

```sh
marple-cli folders create 'Research' --items TAB_A TAB_B --retry-request REQUEST_UUID
```

Recovery returns the original response without repeating the write. Reusing a
key with different arguments returns `request_conflict`. The app retains up to
256 results for 10 minutes, within a 16 MiB budget. After restart, eviction, or
expiry, recovery returns `request_unknown` and performs no write; inspect
`marple-cli tabs list` before issuing a new command. This is recovery within the
running app, not durable exactly-once execution across crashes. The new client
requires an app supporting the `mutate` protocol; older apps reject these writes
before executing them. Older clients remain compatible but have no retry-key
protection.

`ping` reports socket-server liveness independently of the main thread. A
successful ping with a timed-out `tabs list` identifies an unavailable model
request path, rather than proving the UI/indexer healthy.

## Legacy

The earlier Vite + Preact web SPA and Tauri shell, plus the Rust
`reader-api` / `reader-core` sidecar, are archived under [`legacy/`](./legacy/).
They are no longer maintained; the Swift port covers all of their
runtime responsibilities (indexer, search, semantic search included).

## Archive collections

Archive membership can be managed through physical directories marked by `collection.md`.
Use the Archive browser folder strip or `marple-cli collections list/create/rename/move/status`.
See [the collection contract and CLI examples](docs/archive-collections.md) for dry runs,
reference updates, concurrency and recovery. These are independent of sidebar folders.
