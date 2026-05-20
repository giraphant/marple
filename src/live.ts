// Optimistic-concurrency guard for the body editor. The file is the source of
// truth; before overwriting it we compare the current on-disk text against the
// text we last loaded or saved (`lastKnownRaw`). Any difference means another
// window (or an external edit) changed the file underneath us, so we must NOT
// blindly overwrite. A null `diskRaw` means we couldn't confirm the on-disk
// state (GET failed) — also treated as a conflict: never overwrite blind.
export function saveDecision(lastKnownRaw: string, diskRaw: string | null): 'write' | 'conflict' {
  if (diskRaw === null) return 'conflict';
  return diskRaw === lastKnownRaw ? 'write' : 'conflict';
}
