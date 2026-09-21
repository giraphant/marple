# Archive reader

This reader follows Quasi 0.65.39's `docs/ARCHIVE_STORAGE.md` and
`scripts/schemas/archive_manifest.py` (`quasi.archive.manifest/0.1`).

An Archive is one material object with a freeform `archive.md`, optional
`manifest.yaml`, and mixed originals under `originals/`. The reader never
rewrites these files or requires chapters, transcripts, captions, or a quota
of collected files.

## Presentation

- Open the authored Markdown first, including inline images in its own order.
  Images are bounded thumbnails in TextKit; clicking opens the original.
- Keep the existing attachment menu and full reader preview for images/PDF,
  WebKit snapshots, and AVKit audio/video. MIME from the manifest selects the
  viewer; unsupported formats retain an external-open action. Playback does
  not start automatically and stops when the preview closes.
- Show the common source in the reader toolbar and the information inspector.
  Preserve collection order in the original-file inventory. Show unavailable
  local files as disabled rows rather than hiding their provenance.
- On selecting an original, show its inherited/overridden contextual source,
  capture time, declared size, MIME, and a separate download-URL link.
  A CDN asset URL never replaces the contextual source.
- Show `coverage` as prose. An empty inventory means source-only, not an error
  or an offline archive. Empty-body archives still have a source action.
- Existing archives without a manifest retain frontmatter source/url and the
  original root-directory attachment discovery. Valid manifests take precedence
  over legacy source fields. Invalid manifests leave the text readable and
  display an inventory error.

The manifest is read when opening/reloading a document, independently of the
Markdown index. It does not create a second editable metadata source. Hashes
are provenance recorded by Quasi, not a claim that Marple verified every byte.

## Reference

FSNotes (`FSNotesCore/Extensions/NSMutableAttributedString+.swift`,
`loadImagesAndFiles` and attachment metadata) embeds images in the text flow and
retains their original URL for opening. We use the same native text-attachment
approach within Marple's renderer, with downsampled images and resizing bounds.

## Verification

`ArchiveManifestTests` covers source inheritance, MIME selection, ordered files,
missing originals, legacy and empty inventories, invalid versions/paths,
symlink confinement, inline images, metadata precedence, manifest-only reload,
and navigation cleanup. Existing `ArchiveCompatibilityTests` and
`AttachmentPreviewTests` cover indexing and native snapshot/media lifecycle.
Set `MARPLE_ARCHIVE_SNAPSHOT` to a PNG path to capture the composed reader and
inspector from the integration fixture.
