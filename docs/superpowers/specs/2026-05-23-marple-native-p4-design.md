# marple-native — P4 Design: File management

- **Date:** 2026-05-23
- **Status:** Approved (brainstorming) → ready for implementation plan
- **Topic:** Create note / annotation, soft-delete to trash, and a 回收站
  (restore / purge) view for the native macOS reader.
- **Builds on:** P1–P3b (see `2026-05-23-marple-native-reader-design.md` §11,
  phase P4). Master design §6 (write surface) and §4 (`VaultClient` boundary)
  govern this phase.

## 1. Goal & scope

P4 completes the app's write surface beyond metadata: **file management**.

In scope:
- **新建笔记** — create a standalone idea note.
- **新建批注** — create an annotation note targeting a specific entry (writes
  `annotates: <target path>`).
- **移到回收站** — soft-delete an entry to the trash.
- **回收站** — a trash view with **恢复** (restore) and **彻底删除** (purge).

Out of scope (deferred):
- The FSEvents **watcher → full-index refresh** backlog item. P4 keeps state
  fresh via optimistic in-memory updates; external add/delete still leaves
  counts stale until relaunch. (Tracked separately as a freshness backlog item.)
- Settings / reading-typography / ⌘K palette (P5).
- Editing body text in-app (never — this is a reader).
- Author-field editing (a separate later item, per P3).

The Rust backend already exposes every endpoint P4 needs; **all P4 work is
Swift-side.**

## 2. Backend endpoints (existing — reused unchanged)

Verified in `rust/reader-api/src/main.rs` and `rust/reader-core/src/lib.rs`:

| Action | Method + route | reader-core | Response |
|---|---|---|---|
| Create note | `POST /vault/*path` | `post_note` | `201` `{ ok, path, mtime, bytes }` |
| Soft-delete | `DELETE /vault/*path` | `delete_note` | `{ ok, trash }` |
| List trash | `GET /api/trash` | `list_trash` | `{ items: [TrashItem] }` |
| Restore | `POST /api/trash/:name/restore` | `restore_trash` | `{ ok, restored }` |
| Purge | `DELETE /api/trash/:name` | `purge_trash` | `{ ok }` |

Backend invariants P4 relies on (do **not** re-implement Swift-side):
- `post_note` requires the path under `vault/notes/`, requires valid
  frontmatter, and **fails with Conflict if the file already exists**.
- `delete_note` moves the file to `vault/notes/.trash/<base>.<iso-ts>.md`
  (colons/dots in the timestamp replaced by `-`) and returns that path.
- `restore_trash` renames the trash file back to `notes/<base>.md` and
  **fails with Conflict if a same-named note already exists**.
- `TrashItem` JSON keys (serde): `name`, `originalBase` (renamed to camelCase),
  `ts`, `mtime` (number), `size` (number).

## 3. Data boundary — `VaultClient` additions

New DTO in MarpleKit (decodes `/api/trash` directly; camelCase matches serde):

```swift
public struct TrashItem: Sendable, Equatable, Identifiable, Decodable {
    public let name: String          // "<base>.<iso-ts>.md" in .trash/
    public let originalBase: String?
    public let ts: String?
    public let mtime: Double
    public let size: Int
    public var id: String { name }
}
```

Five new protocol methods (all `async throws` — boundary discipline from
master §4; both URLSession and a future UniFFI client fit this shape):

```swift
func createNote(path: String, text: String) async throws    // POST /vault/*path
func moveToTrash(path: String) async throws -> String        // DELETE /vault/*path → trash path
func listTrash() async throws -> [TrashItem]                 // GET /api/trash
func restoreTrash(name: String) async throws -> String       // POST /api/trash/:name/restore → restored path
func purgeTrash(name: String) async throws                   // DELETE /api/trash/:name
```

`HTTPVaultClient` implementation notes:
- `createNote` mirrors `writeFile` but uses `POST` (not `PUT`) to the
  `baseURL + "/" + path` URL (string concatenation, to keep slashes unescaped),
  `Content-Type: text/markdown; charset=utf-8`, body = note text.
- `moveToTrash` issues `DELETE` to the same `/vault/*path` URL; decodes
  `{ trash }` from the response and returns it.
- `listTrash` GETs `api/trash`, decodes `{ items }`.
- `restoreTrash` / `purgeTrash` build `api/trash/<name>[/restore]` with the
  `name` segment percent-encoded (`.urlPathAllowed`); decode `{ restored }` for
  restore.
- Failures map to the existing `VaultError` cases (`.http(status:body:)` carries
  backend Conflict messages, `.backendUnavailable`, `.decode`).

`StubVaultClient` (test double) gains: a create log, a trash-move log, a
seedable `[TrashItem]`, and mutating restore/purge so UI/model flows are
testable without a backend. New methods are added to the protocol, so the stub
must implement all five.

## 4. MarpleKit pure logic

### 4.1 `NoteBuilder` (new, pure, unit-tested)

Ports the web app's `newIdeaDraft` / `newAnnotationDraft` (`src/api.ts`) exactly,
so native and web produce byte-identical note files.

```swift
public struct NoteDraft: Equatable, Sendable {
    public let path: String
    public let text: String
    public let title: String
}

public enum NoteBuilder {
    public static func ideaNote(today: Date = .now, stamp: String = NoteBuilder.stamp()) -> NoteDraft
    public static func annotation(target: Entry, today: Date = .now, stamp: String = NoteBuilder.stamp()) -> NoteDraft
    static func stamp() -> String     // 4-char base-36 of current ms (matches web)
    static func slugify(_ s: String) -> String  // ported from web slugify
}
```

- `today` and `stamp` are injectable → tests assert exact output (default to the
  real clock / random stamp in production).
- **Idea note:** path `vault/notes/<yyyy-mm-dd>-idea-<stamp>.md`; frontmatter:
  ```
  ---
  type: note
  title: "<yyyy-mm-dd> — 新笔记"
  created: <yyyy-mm-dd>
  themes: []
  ---

  # <title>

  ```
- **Annotation:** slug from the target's filename (`slugify`), path
  `vault/notes/<slug>-note-<stamp>.md`; frontmatter adds
  `annotates: <target.path>`; title `对《<target.title or slug>》的批注`.
- Title is YAML-quoted via the same quoting logic that backs
  `FrontmatterPatch.yamlScalar` (expose a shared helper rather than duplicate the
  escaping rules).

### 4.2 `Pane.trash`

Add `case trash` to `Pane` (`Browse.swift`). `entriesForPane(.trash, …)`
returns `[]` — a non-list pane, exactly like the existing `.themesIndex`.
Adding the case forces the compiler to flag every `switch pane` site
(`entriesForPane`, `EntryListView.title`, `AppModel.tabTitle`, `RootView`
content) — each is updated to handle trash.

## 5. AppModel actions + freshness

New state:
```swift
private(set) var trashItems: [TrashItem] = []   // sidebar badge = .count
```
Loaded at boot (in `loadIndex`), on selecting the trash pane, and after each
mutation, via a `loadTrash()` helper.

New actions:
```swift
func newIdeaNote() async
func newAnnotation(for entry: Entry) async
func newAnnotationForOpenDoc() async   // targets openEntry
func moveToTrash(_ path: String) async
func loadTrash() async
func restoreTrash(_ name: String) async
func purgeTrash(_ name: String) async
```

**Create flow** (`newIdeaNote` / `newAnnotation*`):
1. Build the draft (`NoteBuilder`).
2. `client.createNote(path:text:)`.
3. On success, **optimistically append** a known `Entry` to `entries`
   (constructed from the draft — mirrors the web `ideaEntryFromDraft`), then
   `rebuildIndexDerived()` + `recomputeVisible()`.
4. **Reveal**: `open(draft.path)` (navigates the active tab, loads the doc).
5. **Hand off**: `openExternally()` (existing `openInEditor` path) so the user
   can start writing immediately.
6. On failure: do not append; surface via `writeError` / `status`.

**Trash flow** (`moveToTrash`):
1. `client.moveToTrash(path:)`.
2. Remove the row from `entries`; `rebuildIndexDerived()` + `recomputeVisible()`.
3. If the **active tab** is showing that doc (`openPath == path`), navigate it
   back to its pane (`openPath = nil`). Background tabs/history that referenced
   the file degrade to the existing "load failed" placeholder if revisited —
   acceptable for a soft-deleted file.
4. `loadTrash()` to bump the badge.
5. On failure: leave `entries` untouched; surface the error.

**Restore flow** (`restoreTrash`) — the one optimistic exception:
- `client.restoreTrash(name:)`; on success the file re-enters the vault but we
  cannot cheaply reconstruct its parsed `Entry` (no single-entry index endpoint;
  re-deriving frontmatter→Entry is the indexer's job, out of P4 scope). So
  **restore triggers one `loadIndex()` reload**, then `loadTrash()`. Rare action
  → a full refetch is acceptable; the common path stays optimistic.
- On Conflict (same-named note exists): keep the item in trash, surface
  "无法恢复：已存在同名笔记". No reload.

**Purge flow** (`purgeTrash`): `client.purgeTrash(name:)` → drop from
`trashItems` (it was never in `entries`). On failure, keep it.

## 6. UI surfaces

- **SidebarView**: a 回收站 row (`tag(Pane.trash)`, icon `trash`, trailing badge
  `model.trashItems.count`); a 新建笔记 button pinned at the sidebar bottom →
  `newIdeaNote()`.
- **Toolbar + menu**: a `+` toolbar item → `newIdeaNote()`; a
  `CommandGroup(replacing: .newItem)` bound to ⌘N → `newIdeaNote()`, reaching the
  model through the existing `focusedSceneValue(\.appModel)` channel that
  `TabCommands` already uses.
- **EntryListView context menu**: add 新建批注 → `newAnnotation(for: entry)` and
  移到回收站 (`role: .destructive`) → `moveToTrash(entry.path)` (no confirmation —
  reversible), alongside the existing 在新标签页打开.
- **DocView**: a 新建批注 action beside the existing 用外部编辑器打开 button →
  `newAnnotationForOpenDoc()`.
- **TrashView** (new): mounted by `RootView` when `pane == .trash`. A list of
  trash items showing the original name / timestamp / size; each row offers
  恢复 → `restoreTrash(name)` and 彻底删除 (`role: .destructive`, **confirmation
  dialog** — irreversible) → `purgeTrash(name)`. Empty state: "回收站为空".
- **RootView** content `Group` becomes: `.themesIndex` → `ThemesView`,
  `.trash` → `TrashView`, else `EntryListView`. The detail column (`DocView`) is
  empty on the trash pane (`openPath == nil`), which is fine.

Confirmation policy: 移到回收站 and 恢复 are unconfirmed (reversible);
彻底删除 confirms (irreversible).

## 7. Error handling

All five ops throw `VaultError`; the UI reverts the optimistic change and
surfaces the message through the existing `writeError` / `status` channels (no
new error UI; consistent with master §9).

- **Create**: POST Conflict (file exists) or frontmatter rejection → don't
  append; show error. Rare given the random base-36 stamp.
- **Trash**: DELETE failure → `entries` untouched; show error.
- **Restore**: `409 Conflict` (same-named note exists) → keep in trash, show
  "无法恢复：已存在同名笔记"; no index reload.
- **Purge**: failure → keep the item.
- **listTrash**: failure leaves the last-known list with a status note;
  non-blocking.

## 8. Testing

**MarpleKit unit tests (swift-testing):**
- `NoteBuilder.ideaNote` / `.annotation` produce exact path + frontmatter with
  injected `today` + `stamp`; `slugify` cases; YAML title-quoting (colons,
  quotes, CJK).
- `entriesForPane(.trash)` returns `[]`.
- `TrashItem` decodes from a sample `/api/trash` JSON payload (locks the key
  casing, incl. `originalBase`).

**StubVaultClient-backed tests:**
- `createNote` records the posted draft; `moveToTrash` records the path;
  `listTrash` returns seeded items; `restoreTrash` / `purgeTrash` mutate stub
  state.
- AppModel optimistic behavior: after `newIdeaNote` the new `Entry` is in
  `entries` / `counts`; after `moveToTrash` it is gone; after `restoreTrash`
  `loadIndex()` is invoked (assert via a stub call counter).

**Manual GUI (validation gate):**
- Create idea note via toolbar / ⌘N / sidebar; create annotation via list
  context menu + DocView — each reveals in-app **and** opens in the external
  editor.
- Trash an entry → leaves the list, appears in 回收站 with a bumped badge.
- Restore → returns to its type list. Purge → confirmation, then gone.
- Run the suite with the swift-testing framework flags (per the toolchain note:
  `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`).

## 9. Files touched

New:
- `apple/Sources/MarpleKit/NoteBuilder.swift`
- `apple/Sources/MarpleKit/TrashItem.swift` (or fold the DTO into `VaultClient.swift`)
- `apple/Sources/Marple/TrashView.swift`
- MarpleKit + Marple test files for the above.

Modified:
- `apple/Sources/MarpleKit/VaultClient.swift` (protocol + stub + DTO)
- `apple/Sources/MarpleKit/HTTPVaultClient.swift` (5 methods)
- `apple/Sources/MarpleKit/Browse.swift` (`Pane.trash`, `entriesForPane`)
- `apple/Sources/MarpleKit/FrontmatterPatch.swift` (expose YAML-quote helper)
- `apple/Sources/Marple/AppModel.swift` (state + 7 actions + switch updates)
- `apple/Sources/Marple/SidebarView.swift` (回收站 row + 新建 button)
- `apple/Sources/Marple/EntryListView.swift` (context menu + title switch)
- `apple/Sources/Marple/DocView.swift` (新建批注 action)
- `apple/Sources/Marple/RootView.swift` (content switch + toolbar +)
- `apple/Sources/Marple/TabCommands.swift` (⌘N new-item command)

## 10. Risks & open questions

- **Background tabs pointing at a trashed doc** degrade to "load failed" on
  revisit rather than auto-closing (the web app prunes those tabs). Accepted for
  P4 to avoid deeper `Workspace` history surgery; revisit if it feels wrong in
  GUI validation.
- **Trash badge before first load**: shown from `trashItems.count`, populated at
  boot via `loadTrash()`; if that boot call is skipped for latency, the badge
  reads 0 until the pane is first opened. Decide during implementation whether
  the boot load is worth it.
- **Stale counts from external adds/deletes** remain (watcher-index-refresh is
  deferred) — known and accepted.
