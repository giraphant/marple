# Safe SQLite Index Rebuild Design

## Problem

`VaultIndexer.buildFull()` currently builds `index.sqlite.tmp`, unlinks the live
`index.sqlite`, and renames the temporary file into its place. Marple may still
have `IndexDatabase` or `DatabasePool` connections open against the old file.
Those connections and the replacement then share the pathname-derived
`index.sqlite-wal` and `index.sqlite-shm` files, so SQLite can attach an old WAL
to the new main database. SQLite explicitly documents renaming or unlinking an
open database as undefined and potentially corrupting.

The BTS failure was this exact shape: the replacement main database contained
273,743 pages, while the surviving WAL declared a committed size of 381,672
pages. Reading the main file alone passed `quick_check`; reading it with the WAL
failed with `SQLITE_CORRUPT`.

## Decision

Keep the existing offline temporary-database build, but publish it through
GRDB's wrapper around SQLite's Online Backup API instead of replacing the live
filesystem object.

SQLite holds a write transaction on the destination during the backup. A
successful backup makes the destination a snapshot of the temporary source;
an incomplete backup rolls back. Existing readers remain attached to the same
database generation and SQLite continues to own its WAL/SHM lifecycle.

References:

- <https://sqlite.org/howtocorrupt.html#unlinking_or_renaming_a_database_file_while_in_use>
- <https://sqlite.org/c3ref/backup_finish.html>
- NetNewsWire's database cleanup helper treats the main database, `-wal`, and
  `-shm` as one unit:
  `/tmp/marple-reference-repos/NetNewsWire/Modules/ErrorLog/Tests/ErrorLogTests/ErrorLogDatabaseTests.swift`

## Data Flow

1. Walk and parse the vault exactly as today.
2. Read the previous `entries_revision` and build the complete next index in
   `index.sqlite.tmp` with `journal_mode=OFF` exactly as today.
3. Under `VaultIndexer.writeLock`, open the live path with a WAL-mode
   `DatabasePool` and call `tmpQueue.backup(to: livePool)`.
4. After the backup succeeds, remove `index.sqlite.tmp` and `entries.cache`.
5. Return the rebuilt entry count. The live database keeps its inode and valid
   WAL family; the next `IndexDatabase` read observes the committed snapshot.

If no live database exists, opening the destination pool creates it before the
backup. If publication fails, SQLite rolls back the destination write and the
temporary database remains available until the next rebuild removes or
replaces it.

## Test

Add one regression test to `VaultIndexerTests` that:

1. Builds an initial index.
2. Keeps a live WAL connection open and commits enough padding to make the old
   database larger than the replacement.
3. Rebuilds from a smaller vault while that connection remains open.
4. Verifies the rebuilt `entries` count and content through `IndexDatabase`.
5. Runs `PRAGMA quick_check` through a normal WAL-aware connection and expects
   `ok`.

The test must fail against the current filesystem-replacement implementation
before production code changes, then pass with the Online Backup publisher.

## Trade-off and Scope

Publishing rewrites the full database through SQLite and may temporarily grow
the WAL, so it can use more I/O and transient disk space than a rename. Full
rebuilds are rare and already take minutes; correctness and maintainability
outweigh that cost.

This change does not redesign incremental reconcile, cache encoding, semantic
vectors, or recovery of an index that was already corrupted before the fix.
