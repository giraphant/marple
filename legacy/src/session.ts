import type { EntryType, Tab, TabContent } from './types';

// QUA-68: tab state (the open set, each tab's history, and the active index)
// persists in localStorage so it survives app launches AND is the same when the
// reader is opened in another page. The previous QUA-53 design kept the live set
// in per-window sessionStorage, which meant the active tab reset on every fresh
// launch and two open pages drifted apart. We still read the old sessionStorage
// / `:last` keys once as a migration fallback so an in-flight session upgrades
// without losing its tabs.
export const TABS_KEY = 'qua-reader-tabs-v3';
export const ACTIVE_KEY = 'qua-reader-active-tab';
/** Legacy localStorage snapshot written by the old sessionStorage-based design. */
export const LEGACY_SNAPSHOT_KEY = 'qua-reader-tabs-v3:last';

const DEFAULT_TYPE: EntryType = 'paper-analysis';

export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface Stores {
  session: StorageLike;
  local: StorageLike;
}

export function defaultTab(): Tab {
  return { history: [{ kind: 'list', type: DEFAULT_TYPE }], cursor: 0 };
}

function resolveStores(stores?: Stores): Stores | null {
  if (stores) return stores;
  try {
    return { session: window.sessionStorage, local: window.localStorage };
  } catch {
    return null;
  }
}

function isValidContent(c: unknown): c is TabContent {
  if (!c || typeof c !== 'object') return false;
  const cc = c as Record<string, unknown>;
  switch (cc.kind) {
    case 'list': return typeof cc.type === 'string';
    case 'doc': return typeof cc.path === 'string';
    case 'trash':
    case 'themes':
    case 'activity': return true;
    default: return false;
  }
}

function isValidTab(t: unknown): t is Tab {
  if (!t || typeof t !== 'object') return false;
  const obj = t as Record<string, unknown>;
  if (!Array.isArray(obj.history) || obj.history.length === 0) return false;
  if (typeof obj.cursor !== 'number') return false;
  return obj.history.every(isValidContent);
}

/** Parse a stored tabs blob into a clean Tab[], or null if nothing usable. */
function sanitizeTabs(raw: string | null): Tab[] | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return null;
    const clean = parsed.filter(isValidTab);
    return clean.length > 0 ? clean : null;
  } catch {
    return null;
  }
}

export function loadTabs(stores?: Stores): Tab[] {
  const s = resolveStores(stores);
  if (!s) return [defaultTab()];
  return (
    sanitizeTabs(s.local.getItem(TABS_KEY)) ??           // authoritative
    sanitizeTabs(s.session.getItem(TABS_KEY)) ??         // migrate: old per-window live set
    sanitizeTabs(s.local.getItem(LEGACY_SNAPSHOT_KEY)) ?? // migrate: old reopen snapshot
    [defaultTab()]
  );
}

export function loadActiveIndex(tabCount: number, stores?: Stores): number {
  const s = resolveStores(stores);
  const upper = Math.max(0, tabCount - 1);
  if (!s) return 0;
  const raw = s.local.getItem(ACTIVE_KEY) ?? s.session.getItem(ACTIVE_KEY); // migrate old session value
  const n = raw == null ? 0 : parseInt(raw, 10);
  if (!Number.isFinite(n)) return 0;
  return Math.min(Math.max(0, n), upper);
}

export function saveTabs(tabs: Tab[], stores?: Stores): void {
  const s = resolveStores(stores);
  if (!s) return;
  try { s.local.setItem(TABS_KEY, JSON.stringify(tabs)); } catch {}
}

export function saveActiveIndex(activeIndex: number, stores?: Stores): void {
  const s = resolveStores(stores);
  if (!s) return;
  try { s.local.setItem(ACTIVE_KEY, String(activeIndex)); } catch {}
}
