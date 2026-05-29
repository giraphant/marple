# Marple Auto-Backup — Local APFS Snapshots (QUA-106)

**Goal:** Give the vault a quiet, automatic, in-app safety net for recovery: periodic whole-vault snapshots on the local disk, with Ulysses-style tiered retention and per-document "restore as a side copy".

**Why snapshots, not git auto-commit:** The original idea ("auto-commit on meaningful change") conflates two jobs. Frequent automatic *commits* are noisy and git is bad at large binaries (big PDFs exceed GitHub's 100 MB limit). A snapshot is invisible by construction — the user never sees a commit log — and APFS block-cloning makes whole-vault snapshots near-instant and near-free in space. This is what Ulysses does, and it handles the multimedia layer that git can't.

**Why local-only, no cloud:** Off-machine durability and historical depth are already covered by the user's existing **Time Machine** routine (separate physical disk, its own tiered retention). Off-site/cloud redundancy, if wanted, is handled by syncing the **vault itself** through Nextcloud (one live copy, naturally incremental) — *not* by syncing snapshots (each snapshot reads as all-new files to a file-sync client and would explode server storage). So cloud stays entirely outside Marple's code. This feature is the convenience layer Time Machine's clunky restore UX can't give: in-app, vault-scoped, single-document restore.

## Scope

In scope (this spec):
- Automatic, invisible whole-vault snapshots to a local directory.
- Tiered retention matching Ulysses (hourly / daily / weekly).
- A `备份` settings tab: enable toggle, fixed retention description, last-backup time, `立即备份`, `浏览备份…`, and a backup-location picker.
- A browse/restore window: list snapshots by friendly time → pick a document → restore as a side copy (never overwrites current). Plus a "在 Finder 中打开此快照" escape hatch for whole-vault needs.

Explicitly **out of scope** (deferred, separate work):
- **Manual git commit / "标记版本"** (the milestone track). The user is still working out its interaction. → Linear follow-up.
- **Cloud / off-site sync.** Handled by Time Machine + optional Nextcloud-on-the-vault, no Marple code.
- **git diff / git restore UI.** Use external git tooling against the vault.
- **Whole-snapshot bulk restore** that overwrites the live vault. Restore is single-file-as-copy only; Finder escape hatch covers the rest.

## Architecture

```
                 every N min (default 15), only if dirty
                 ┌──────────────────────────────────────┐
VaultWatcher ──▶ │ BackupScheduler (@MainActor)          │
 (dirty flag)    │   tick → SnapshotStore.snapshot()     │
                 │        → SnapshotStore.prune(policy)   │
                 └───────────────┬──────────────────────┘
                                 │ clonefile(2) vault → temp → atomic rename
                                 ▼
        <backupRoot>/<vault-id>/2026-05-29T14-30-00/   (one whole-vault clone)
                                 ▲
        BackupBrowser ──────────┘ list / restore-one-file-as-copy / reveal-in-Finder
```

- **Engine in `MarpleKit/Backup/`** (pure, testable, no UI). **Scheduler + UI glue in `Marple/Backup/`** and `Marple/Settings/`.
- The snapshot is a recursive `clonefile(2)` of the vault root into a timestamped sibling under the backup root. On APFS-same-volume this shares blocks (near-zero extra space); cross-volume / non-APFS falls back to a full recursive copy.
- The backup root lives **outside** the vault `workspaceRoot` (no snapshot-of-snapshots, git never tracks it).

## Components

### `MarpleKit/Backup/RetentionPolicy.swift` (pure)
Given a list of snapshot timestamps and `now`, returns the set to delete. Tiers (Ulysses):
- **last 12h:** keep newest per *hour* bucket.
- **12h–7d:** keep newest per *day* bucket.
- **7d–6mo:** keep newest per *week* bucket.
- **>6mo:** delete.

Pure function over `[Date]` → `(keep: [Date], delete: [Date])`. Fully unit-tested; this is where the density logic lives so creation cadence can be finer without changing visible density.

### `MarpleKit/Backup/CloneCopy.swift`
Thin wrapper over `clonefile(2)` for a directory tree, with a recursive-copy fallback when `clonefile` fails (`EXDEV` cross-volume, non-APFS). Exclusions are applied during copy: skip `.marple/` (rebuildable ~1GB cache), `.git` (9.1GB binary-heavy history — itself a history mechanism), `.DS_Store` (Finder junk), and `.sync_*` (Nextcloud/ownCloud sync journal). Everything else is cloned.

### `MarpleKit/Backup/SnapshotStore.swift`
Owns the backup root for one vault. API:
- `snapshot() throws -> Snapshot` — clone vault into `…/<temp>`, then atomic-rename to the timestamped name (crash-safe: a half-clone never appears valid).
- `list() -> [Snapshot]` — parse timestamped dir names, newest first.
- `prune(now:) throws` — apply `RetentionPolicy`, delete dropped snapshot dirs.
- `restoreCopy(snapshot:relPath:into:) throws -> String` — copy one file/dir out of a snapshot into the live vault under a non-colliding, suffixed name; returns the new rel path.
- `lastBackupDate -> Date?`

`Snapshot` = `{ date: Date, url: URL }`. Vault id = stable hash of `workspaceRoot` so multiple vaults don't collide under a shared backup root.

### `Marple/Backup/BackupScheduler.swift` (`@MainActor`)
- Subscribes to `VaultWatcher` change events to maintain a `dirty` flag (set on change, cleared after a successful snapshot). Avoids redundant identical snapshots.
- A `Timer` fires every `interval` (default 15 min). On tick, if `backupEnabled` && `dirty`: run `snapshot()` then `prune()` off the main actor; update last-backup time; clear `dirty`.
- Exposes `backupNow()` (forces a snapshot regardless of dirty), used by the `立即备份` button.
- Constructed by `AppState.boot` after `AppModel`/vault are ready, honoring `marple.backupEnabled`.

### `Marple/Settings/` — `备份` tab
Mirrors the Ulysses panel (see issue screenshots), restrained chrome:
- `备份已启用` toggle (`marple.backupEnabled`).
- Fixed descriptive text of the retention tiers (static, not user-tunable — matches the mature product):
  - 过去 12 小时每小时保留一份
  - 过去 7 天每天保留一份
  - 过去 6 个月每周保留一份
- `最新备份：<friendly time>`.
- `立即备份` and `浏览备份…` buttons.
- **备份位置** picker (folder chooser, `marple.backupLocation`). Help note: 默认存于本机；改到外挂盘/网络盘会变成完整拷贝（无块去重），且云同步请同步文库本体而非备份目录。

### `Marple/Backup/BackupBrowserView.swift`
Opened by `浏览备份…`. Lists snapshots by friendly timestamp. Selecting one shows its document tree; per document:
- `恢复为副本` → `SnapshotStore.restoreCopy(...)` into the live vault with a suffixed name (e.g. `<title> (恢复自 2026-05-28 21-00).md`); the running `VaultWatcher`/index picks it up. Never overwrites the current document.
- `在 Finder 中打开此快照` → reveal the snapshot dir for any manual whole-vault needs.

## Settings Keys (added to `SettingsKeys`)
- `marple.backupEnabled` — `Bool`, default **true** (cheap + it's a safety feature; matches Ulysses default-on).
- `marple.backupLocation` — `String` path; empty ⇒ default `~/Library/Application Support/Marple/Backups/`.

Interval and retention tiers are constants, not user settings, to keep the panel as simple as the reference product.

## File Layout
```
apple/Sources/
├── MarpleKit/Backup/
│   ├── RetentionPolicy.swift     # pure tier logic (unit-tested)
│   ├── CloneCopy.swift           # clonefile(2) + recursive-copy fallback, exclusions
│   └── SnapshotStore.swift       # snapshot / list / prune / restoreCopy
└── Marple/Backup/
    ├── BackupScheduler.swift     # @MainActor timer + VaultWatcher dirty flag
    └── BackupBrowserView.swift   # browse + restore-as-copy + reveal-in-Finder
# edits: Marple/Settings/AppSettings.swift (keys), Marple/Settings/SettingsView.swift (备份 tab),
#        AppState.boot (construct scheduler)
```

## Edge Cases & Safety
- **Atomic snapshots:** clone to a temp name, then rename — a crash mid-clone leaves no valid-looking partial.
- **Backup root must be outside the vault** to prevent recursive snapshots and git tracking.
- **Change detection** uses the `VaultWatcher` dirty flag, not a full tree walk per tick.
- **Cross-volume / non-APFS** silently falls back to full copy (correct, just not space-deduped) — surfaced via the location help note.
- **Excluded from snapshots:** `.marple/` (rebuildable), `.git` (9.1GB binary-heavy history), `.DS_Store`, `.sync_*` (sync journal). Everything else cloned.
- **Restore never overwrites:** single-file-as-copy only.

## Testing
- `RetentionPolicy`: bucket math across hour/day/week/6-month boundaries, DST, empty/dense inputs.
- `CloneCopy`: round-trip a temp tree via the fallback path; verify `.marple/` excluded.
- `SnapshotStore`: snapshot → list → prune → restoreCopy on a temp dir (fallback copy mode); verify suffixed non-colliding restore name and that the original is untouched.

## Cross-References
- QUA-106 issue thread (Ulysses backup panel screenshots; "commits are noisy" reasoning).
- Manual git "标记版本" track — Linear follow-up (interaction TBD).
- "Historical depth off-site via restic/borg" — Linear follow-up (only if Time Machine + Nextcloud-on-vault ever proves insufficient).
