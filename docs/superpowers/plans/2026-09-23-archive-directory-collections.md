# Archive directory collections — implementation plan

## Agreed contract

Only Archive, one collection level, under `vault/archives/`. A collection directory
contains `collection.md` (empty is valid); an Archive contains `archive.md` and keeps
its original manifest and originals. Membership is physical parentage. No member
lists, no collection manifest, no frontmatter collection field. Display title is
first Markdown H1, otherwise directory name. An Archive and Collection marker in
the same directory is invalid. Books and mixed collections are outside this change.

## Delivery order and acceptance

1. Integrate the installed Archive 0.2 branch with current CLI transport/replay work
   in an isolated checkout. Preserve the user's dirty main worktree.
2. Implement shared discovery and checked filesystem operations: list, create,
   rename, move archives into/between collections, move back to archive root.
   Test empty markers, Unicode names, missing sources, duplicate destinations,
   case-insensitive collisions, traversal/symlinks, mixed markers, nested groups.
3. Plan changes before writing. Return old/new directory mapping and affected
   references. Dry run changes nothing. Preserve original bytes of files and keep
   a recovery record for uncertain/interrupted multi-file operations. Never
   overwrite another Archive. A batch is preflighted in full.
4. Update supported Markdown/wiki and structured path references; preserve local
   originals links. Remap all open/pinned/history paths before pruning/reindexing.
   Test existing source modifications and interrupted/failed operations.
5. Add `marple-cli collections list/create/rename/move`, with `--dry-run`, JSON
   output, and stable operation identity for inspecting/retrying lost responses.
   Use the same service as GUI; do not confuse these with sidebar `folders`.
6. Show collections in Archive browsing, open a collection's member list, provide
   back-to-root navigation and creation/rename actions. Native selected Archive
   drags move directories onto collection targets or the archive root target.
7. Regression: parser/index/reader/CLI/navigation suites, real temporary-vault
   create → move → rename → move out; never reorganize the user's live vault for
   testing. Build/sign/install after verification using existing signing config.
8. Deliver Quasi handoff with exact tree, path discovery/identity changes, locking,
   relative-link and mutation semantics, commands, and acceptance fixtures.

## Cross-project boundary

The user subsequently authorized editing Quasi directly. Adapt discovery, status,
resolve, collection writes, Topic path schema and generated workflow contracts in
`/Users/ramudai/Vibe/quasi`. Preserve existing unrelated changes. Do not publish or
bump a release version; leave a release handoff and verified tests for the user.

## Important limits

Directory moves and reference edits are multiple filesystem operations, not a
filesystem transaction. Preflight, recovery records and explicit incomplete-state
reporting must not be described as cross-device/cloud atomicity. Finder moves do
not carry Marple's reference-update transaction. Discovery reflects them, but
arbitrary external moves cannot promise automatic repair without stable identity.
