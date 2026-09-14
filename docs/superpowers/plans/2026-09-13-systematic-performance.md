# macOS navigation and index performance

Completed performance pass for v0.2.12. Preserve complete tab/Space state, search
results, Unicode rendering, note saves, and index transaction boundaries.

## Implementation

- Batch navigation persistence once before document loading; skip unchanged
  control values and resolve cached titles/types only for open tabs.
- Share Catalog's path and author indexes across navigation, sidebar and inspector
  reads. Rebuild them when the entry snapshot changes; preserve observation and
  the first-match behavior of duplicate paths.
- Replace reflected sidebar signatures with typed snapshots. Retain unchanged
  object/view nodes across Space changes, avoid rebuilding for browse selection,
  and resolve pinned membership once per tree evaluation.
- Publish background relation graphs before search-index construction finishes.
  Coalesce updates into one active worker and reject stale publications.
- Measure repeated CJK table tokens once per column/font, retaining exact UTF-8
  spelling and cell boundaries. Bound preview-prefix copying and remove duplicate
  body normalization while preserving output.
- Skip cloud-evicted optional entries caches. Delete changed FTS paths as one
  batch inside the existing metadata/index transaction.
- Publish full index rebuilds through GRDB's SQLite backup API, preserving open
  WAL snapshots. Match destination page size, use separate temporary files, and
  select the next revision under the existing writer lock. Read cached entries
  and their revision in one transaction and invalidate stale schema metadata.
- Configure SO_NOSIGPIPE on the listening socket so accepted CLI connections
  inherit protection even when clients disconnect before acceptance.

Existing implementations inspected: NetNewsWire's persistent sidebar nodes and
serialized database access, FSNotes' direct entry lookup, and GRDB's native
backup API. SQLite documents the hazards of replacing open database files in
[How To Corrupt An SQLite Database](https://www.sqlite.org/howtocorrupt.html).
No new dependency or persisted-session format was introduced.

## Measurements

Release measurements used a 611-tab/6-Space saved session and a library with
approximately 32,000 entries. Private session data and runtime logs remain local.

| Controlled measurement | Before | After |
| --- | ---: | ---: |
| Navigation session saves | 3–5 saves per switch | 1 save per switch |
| Pinned-list getter, largest visible Space | 9.77 ms | 0.23 ms |
| Sidebar Space update, retained nodes pass | 41.19 ms | 29.99 ms |
| Synthetic repeated CJK table rendering, first pass | 147.08 ms | 25.67 ms |
| Production reconcile deleting 600 entries / 25.8 MB text | 2477.00 ms | 353.35 ms |

These are isolated segment medians from the relevant before/after runs, not
additive savings or screen click-to-paint measurements. The final navigation
regression measured Space-model / sidebar / viewport medians of 31.25 / 26.05 /
24.78 ms. Its fixed document bodies isolate navigation and native sidebar work.

An offline rebuild indexed 32,178 documents in 166.05 seconds. SQLite quick_check
and FTS5 integrity-check passed. A separate native backup probe copied that
1.76 GB index in 2.689 seconds while a reader retained its old snapshot; its next
read saw all rebuilt entries and passed quick_check.

## Verification

- 1,029 Release tests passed; the release-preparation rerun completed in 2.695 s.
- The 611-tab/6-Space navigation regression passed in 16.606 s.
- Regression coverage includes full navigation context saved before suspended
  document reads, duplicate/missing path lookup and observation, sidebar node
  identity/selection/collapse behavior, exact Unicode token widths, FTS batch
  escaping/duplicates/rollback, and WAL readers across full rebuilds.
- The WAL regression failed with SQLite I/O error 10 before the fix. The fixed
  suite also verifies schema publication to an existing reader and an actual
  8192-byte-page legacy database.
- Independent integration review found no release blocker. Installed local
  verification retained tabs, Spaces and active selection, loaded the rebuilt
  corpus without reconcile errors, and returned to an idle event loop.
- This host has Swift 6.1.2/macOS 15.5 Command Line Tools, not full Xcode. Local
  testing used temporary SDK compatibility shims and existing, unchanged
  localized resources; shims are excluded from source control. Release signing,
  notarization and distribution are separate checks.

## Remaining work

- Safely coordinate offline recovery when a damaged SQLite header/schema cannot
  be opened. Online rebuild now fails safely in that case; never unlink a live
  database while readers still hold it. The original archived journal mismatch
  does not by itself identify the actor that caused corruption.
- Measure remaining persistence and real reading-pane latency with representative
  bodies/fonts and an actual window. Full session encoding still costs about
  17 ms, and long-run memory/GUI latency needs broader sampling.
- Investigate index cache decode (about 1.0 s versus 0.52 s for warm SQL), cloud
  file materialization, cancellation of running indexed queries, and the one
  FTS scan still required per changed reconcile. Persisted FTS rowids would need
  migration evidence before replacing the current bounded batch implementation.

Reproduce opt-in benchmarks with `MARPLE_PERFORMANCE_BENCH=1` and explicit
`MARPLE_PERFORMANCE_VAULT` / `MARPLE_PERFORMANCE_STATE` paths when desired. Run
`swift test --package-path apple -c release --filter PerformanceBenchmarkTests`.
