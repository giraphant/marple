# Marple iOS Companion — Design (v1)

> Status: approved design, pre-implementation.
> Scope: a **read-only iPhone reader** over the same vault, served by **standard
> iCloud Drive file sync** (no CloudKit, no app-level sync engine).

## 1. Goal & scope

A read-only iPhone companion to the macOS Marple reader. It points at the same
vault folder the user already syncs via **iCloud Drive** and lets them browse and
read on the phone.

**In v1:**

- 6-type sidebar → entry list → markdown reader (the core read path).
- Full-text search (FTS5 trigram, CJK) — reuses `IndexDatabase`.
- Inspector panel: frontmatter / stats / outline — reuses `Derivation`.

**Deferred to v2 (explicitly out of scope):**

- Card / waterfall grid view.
- PDF / translation viewing.
- Semantic search (MLX / Qwen3-Embedding).
- Any write operations (create note, edit frontmatter, trash).

## 2. Data path: standard iCloud Drive, read-only

The app does **not** sync anything. iCloud Drive already replicates the vault
folder to the phone, exactly as it would any folder. The app only reads files.

- ❌ No CloudKit / `NSPersistentCloudKitContainer`.
- ❌ No iCloud key-value store.
- ❌ No writes back to the synced vault.
- ✅ Point at the already-synced folder, read its `.md` files.

The only iCloud-specific code handles **eviction**: iCloud Drive turns
not-recently-used files into 0-byte placeholders to save space. Reading one
requires `startDownloadingUbiquitousItem` + awaiting materialization. This is
on-demand download of standard iCloud Drive files, not a sync layer.

Same mental model as the Mac, which reads the vault folder directly — the only
difference is that on the phone, iCloud Drive is what put the folder there.

## 3. Repo layout & build

- `apple/Package.swift`: add `.iOS(.v17)` to `platforms`. **No change to the
  macOS app or its targets.**
- New `apple/ios/MarpleiOS.xcodeproj`: a SwiftUI iOS app target that consumes
  the local `../apple` package's `MarpleKit` product.
  - iOS apps cannot be `swift run` — they need an Xcode app bundle + code
    signing. Runs on the user's own iPhone via a personal dev certificate.
- The iOS app depends on **MarpleKit only** → pulls in swift-markdown + GRDB +
  Yams + Tokenizers. **Zero MLX/Metal** — that lives in the separate
  `MarpleEmbeddings` target, which the iOS app does not reference.

## 4. Components

### Workstream A — Make MarpleKit iOS-buildable

Mechanical platform-guarding. Some MarpleKit files use APIs that do not exist on
iOS and would otherwise fail to compile.

| File | Issue | iOS treatment |
|------|-------|---------------|
| `Indexer/GitDates.swift` | spawns `git` via `Process` (macOS-only) | `#if os(macOS)` the git path; iOS fallback = file mtime for "added date" (approximate, acceptable for a reader) |
| `Vault/VaultWatcher.swift` | FSEvents (macOS-only) | `#if os(macOS)` whole file; iOS does not use it |
| `Vault/SupersetRunner.swift` | `Process` (macOS-only) | `#if os(macOS)` whole file; iOS does not use it |
| `Vault/LocalVaultClient.swift` | `NSWorkspace` / `Process` open methods | `#if os(macOS)` whole file; iOS gets its own client (Workstream B) |
| `Markdown/AttributedStringRenderer.swift` | `NSFont` / `NSColor` **and AppKit table-drawing chrome** | full cross-platform port (see below) |

`AttributedStringRenderer.swift` is the **largest port**, bigger than fonts/colors
alone. Beyond `NSFont`/`NSColor`, its rounded-card table rendering is genuine
AppKit drawing: `RoundedCardBlock`/`TableCellBlock` subclass `NSTextTableBlock`
and override `drawBackground(...)` using `NSBezierPath` + `NSGraphicsContext`
(the "path D" live-text table chrome). The port:

- `Platform.swift` (new): `PlatformFont`/`PlatformColor`/`PlatformBezierPath`
  typealiases (`NSFont`/`NSColor`/`NSBezierPath` ↔ `UIFont`/`UIColor`/`UIBezierPath`),
  plus the few diverging calls (`NSFontManager` weights, `addLine`/`line(to:)`,
  graphics-context save/restore/clip).
- The `drawBackground(...)` signatures differ by platform (`in controlView: NSView`
  vs `UIView`); guard those method bodies per-platform while sharing the geometry.
- `NSTextTable`/`NSTextTableBlock`/`NSParagraphStyle`/`NSMutableParagraphStyle`/
  `NSTextTab` exist in UIKit's TextKit, so the layout math is shared.
- Output stays an `NSAttributedString` (a cross-platform class), so the **reading
  experience is identical to the Mac**.

The rendered `NSAttributedString` is displayed on iOS in a **`UITextView`**
(`UIViewRepresentable`), mirroring the Mac's `MarkdownTextView` (`NSTextView`,
`NSViewRepresentable`). This is the chosen path over degrading tables or
re-rendering blocks natively in SwiftUI — highest fidelity, maximum reuse, no
divergence from the Mac renderer.

### Workstream B — iOS file access (the only genuinely new logic)

- **`VaultBookmark`** — `UIDocumentPicker` (folder mode) → user picks the synced
  vault folder once → persist a **security-scoped bookmark** in `UserDefaults`.
  On launch, resolve the bookmark and call
  `startAccessingSecurityScopedResource()`. (iOS analogue of the Mac workspace
  picker, which also uses security-scoped bookmarks underneath.)
- **`ICloudMaterializer`** — ensure a file is actually present before reading:
  inspect `URLResourceValues.ubiquitousItemDownloadingStatus`, call
  `FileManager.startDownloadingUbiquitousItem(at:)`, await materialization
  (poll resource values or observe via `NSMetadataQuery`). **Only `.md` files**
  are force-downloaded; heavy media/PDFs are left evicted (v2 territory).
- **`IOSVaultClient: VaultClient`** — the new platform implementation of the
  existing protocol seam:
  - `index()` / `search(_:)` delegate to the on-device `IndexDatabase`.
  - `entryText(path:)` materializes-then-reads the file.
  - macOS-only methods (open-in-editor, openPDF, media URLs) return the
    protocol's no-op defaults or `nil`.

### Workstream C — On-device index

- On first launch (after the folder is picked) and on **app foreground**, run
  `VaultIndexer.reconcile()` over the synced `.md` files into
  `<appContainer>/index.sqlite` — the app's **private** container, never the
  synced vault.
- `reconcile()` is incremental, so foreground refreshes only re-read changed
  files and are cheap.
- No FSEvents on iOS — **app-foreground is the refresh trigger**.
- Indexing the whole vault (hundreds–low-thousands of small `.md`) is seconds on
  a modern iPhone.

### Workstream D — iOS UI shell (all-new SwiftUI, no AppKit)

- `NavigationStack`: `SidebarScreen` (6 types) → `EntryListScreen(type)` →
  `DocScreen(entry)`. Single-column push navigation (iPhone-only).
- Search: `.searchable` on the list, querying `IndexDatabase` FTS5.
- `DocScreen`: wraps a `UITextView` (`UIViewRepresentable`) that displays the
  `NSAttributedString` from `MarkdownRenderer.render(...)`, fed by
  `Wikilink.preprocessForRendering(body)` + `RenderStyle(...)` — same pipeline as
  the Mac's `DocView`/`MarkdownTextView`. Inspector is a sheet built on
  `Derivation`'s `computeDocStats(...)` / `outline(from:)`.
- A lean iOS `ReaderModel` (`@Observable`). The Mac's `AppModel` lives in the
  macOS UI target and is not reusable, but a read-only model is far simpler, and
  all derivations come from MarpleKit.

## 5. Data flow (boot)

Single assembly point, mirroring the Mac's `AppState.boot`:

```
resolve bookmark
   │  (none? → UIDocumentPicker → save bookmark)
   ▼
startAccessingSecurityScopedResource
   ▼
enumerate vault .md  →  materialize missing (ICloudMaterializer)
   ▼
VaultIndexer.reconcile  →  <appContainer>/index.sqlite
   ▼
IndexDatabase  →  IOSVaultClient  →  ReaderModel  →  SwiftUI
```

## 6. Error handling

- **No / revoked bookmark** → re-prompt the document picker.
- **File not yet downloaded** → show a "正在从 iCloud 下载…" state, trigger the
  download, retry. This is the main real-world failure mode.
- **Index build failure** → surface it with a retry; keep the last good index.

## 7. Testing

- Re-run the **existing MarpleKit macOS tests** after platform-guarding — the
  port must not regress the Mac build (regression guard).
- New iOS unit tests:
  - `VaultBookmark` resolve round-trip.
  - `ICloudMaterializer` downloading-status mapping.
  - `IOSVaultClient` against a fixture vault + on-device `IndexDatabase`.
- Indexer correctness is already covered by shared MarpleKit tests; the iOS
  build inherits it (same indexer code).

## 8. Effort

**~1.5–2 weeks focused** (revised up: the `AttributedStringRenderer` table-chrome
port is bigger than first scoped). Reuse-heavy in B's index path and C. Risk
concentrated in:

- **A** — porting the AppKit table-drawing chrome in `AttributedStringRenderer`
  to UIKit (`NSBezierPath`→`UIBezierPath`, graphics context, per-platform
  `drawBackground`). The rest of A is mechanical `#if os(macOS)`.
- **B** — iCloud materialization timing and the not-yet-downloaded UX.

## 9. Open follow-ups (file in Linear before merge if they survive)

- v2 features: card/grid, PDF/translation viewing, semantic search, writes.
- Whether on-foreground reconcile is responsive enough at the real vault size,
  or whether an `NSMetadataQuery`-driven incremental refresh is worth adding.
