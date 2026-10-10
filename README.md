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
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift build --build-system native
xcrun swift run --build-system native Marple
```

macOS 27 builds require full Xcode for the SwiftUI macro plugins. The bundle
script selects the installed Xcode when the global selection still points to
Command Line Tools. The native SwiftPM backend preserves the bundle script's
product paths. Tests on this Mac also need the explicit Testing framework path:

```sh
cd apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --build-system native \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
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

## Terminology index

Marple builds `.marple/terms.sqlite` in each vault workspace in the background
and updates it when Markdown documents change. Settings → Index → Terminology
Index shows term, correspondence and source counts, with refresh and rebuild
actions. Rebuilding the ordinary or vector index does not replace this file.

The index extracts Chinese–English pairs from tables under 关键概念, 关键术语,
术语表, Key Concepts, Key Terms or Glossary headings. A row is skipped entirely
if either term cell contains a slash (/ or ／), semicolon, 、, or a line break
(including HTML br tags). Compound rows are never split or cross-paired.
Multiple translations from separate single-term rows are preserved, together
with definitions, original cell text and source paths/line numbers. Case and
whitespace are normalized for lookup. Parser version changes automatically
rebuild the terminology index on its next refresh, removing previously split pairs.

Settings → Search has separate experimental terminology-expansion switches for
balanced (full-text) and deep (semantic) search, both **off by default**. The current
index stores unverified candidates: even a single concept label may describe a
context rather than translate the foreign term. These records must not be treated
as a validated synonym dictionary.
When explicitly enabled, expansion defaults to two hops, adjustable from one to five.
At each hop, each term keeps at most five counterparts ranked by the number of
distinct source documents, with normalized term order breaking ties. If a term has
multiple counterparts, each retained pair must occur in at least two documents;
a sole counterpart may occur once. This check includes already visited terms,
and an empty selection stops that branch. Repeated rows in one document count once.
The raw index and CLI lookup retain all accepted single-term candidates and sources;
frequency filtering only applies to search expansion.
Broader depths can produce hundreds of queries and unrelated results. Fast search is unchanged.
Original and expanded queries run separately, preserving surrounding query text;
multiple matched concepts are substituted one at a time. Results are deduplicated
by path and merged using reciprocal rank fusion. Each query keeps the existing
300 full-text / 80 semantic candidate limits and semantic similarity threshold.
“View all” reuses the full palette result set and preserves its search mode.

With the app running and its CLI server enabled:

```sh
marple-cli terms status
marple-cli terms lookup '惯习'
marple-cli terms lookup 'habitus'
marple-cli terms refresh
marple-cli terms refresh --rebuild
```

Lookup returns deduplicated direct counterparts with all document sources. It
refreshes changed documents first. A failed refresh/rebuild retains the previous
committed index. To correct an extracted correspondence, edit its source table.

## Legacy

The earlier Vite + Preact web SPA and Tauri shell, plus the Rust
`reader-api` / `reader-core` sidecar, are archived under [`legacy/`](./legacy/).
They are no longer maintained; the Swift port covers all of their
runtime responsibilities (indexer, search, semantic search included).

## Archive collections

Archive membership can be managed through physical directories marked by `collection.md`.
Use mixed Archive/collection rows, selection context menus and drag-to-group, or `marple-cli collections list/create/rename/move/status`.
See [the collection contract and CLI examples](docs/archive-collections.md) for dry runs,
reference updates, concurrency and recovery. These are independent of sidebar folders.
