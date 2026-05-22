/**
 * QUA-68: per-document read-mode scroll memory.
 *
 * Each doc tab must keep its OWN scroll position. The DocView reuses a single
 * scroll container across docs (no React key per doc), so without an explicit
 * per-doc store the previous doc's pixel offset bleeds onto the next one when
 * switching tabs. We key by vault path — DocTabs dedupe by path, so per-path
 * == per-tab, and revisiting a doc later restores where you left off.
 *
 * UI ephemera, so it lives in localStorage like doc-panel.ts / settings.ts.
 * A flat `{ [path]: scrollTop }` map, capped so it can't grow without bound;
 * JS preserves string-key insertion order, so the oldest keys evict first.
 */

export const SCROLL_KEY = 'qua-reader-doc-scroll';
/** Keep at most this many docs' positions; oldest evicted first (insertion order). */
export const SCROLL_CAP = 200;

export interface StorageLike {
  getItem(k: string): string | null;
  setItem(k: string, v: string): void;
}

function safeLocalStorage(): StorageLike | undefined {
  try { return typeof localStorage !== 'undefined' ? localStorage : undefined; } catch { return undefined; }
}

function readMap(storage: StorageLike): Record<string, number> {
  try {
    const raw = storage.getItem(SCROLL_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
    const out: Record<string, number> = {};
    for (const [k, v] of Object.entries(parsed)) {
      if (typeof v === 'number' && Number.isFinite(v) && v >= 0) out[k] = v;
    }
    return out;
  } catch {
    return {};
  }
}

/** Last saved scroll offset for `path`, or 0 when unknown / unreadable. */
export function loadScroll(path: string, storage: StorageLike | undefined = safeLocalStorage()): number {
  if (!storage || !path) return 0;
  const v = readMap(storage)[path];
  return typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : 0;
}

/** Persist `top` for `path`. Non-finite / negative values clamp to 0. Re-inserts
 *  the key (LRU-fresh) and evicts the oldest entries past SCROLL_CAP. */
export function saveScroll(path: string, top: number, storage: StorageLike | undefined = safeLocalStorage()): void {
  if (!storage || !path) return;
  const clamped = Number.isFinite(top) && top > 0 ? Math.round(top) : 0;
  const map = readMap(storage);
  delete map[path];        // drop so re-insert moves it to the freshest slot
  map[path] = clamped;
  const keys = Object.keys(map);
  if (keys.length > SCROLL_CAP) {
    for (const k of keys.slice(0, keys.length - SCROLL_CAP)) delete map[k];
  }
  try { storage.setItem(SCROLL_KEY, JSON.stringify(map)); } catch {}
}
