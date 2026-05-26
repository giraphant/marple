/**
 * QUA-57: persistence for the DocView right panel (tabbed: 目录 / 信息 / 统计).
 *
 * UI ephemera, so it lives in localStorage like session.ts / settings.ts —
 * deliberately NOT threaded through the main Settings object. State is global
 * (one panel width / collapsed / active tab shared across docs), which matches
 * how the old fixed-width panels behaved.
 */

export type DocPanelTab = 'toc' | 'info' | 'stats';

export interface DocPanelPrefs {
  tab: DocPanelTab;
  collapsed: boolean;
  /** Expanded width in px. */
  width: number;
}

export const DOC_PANEL_MIN_WIDTH = 220;
export const DOC_PANEL_MAX_WIDTH = 520;
export const DOC_PANEL_DEFAULT_WIDTH = 288; // = the old w-72 PropertyPanel

const TABS: ReadonlySet<string> = new Set<DocPanelTab>(['toc', 'info', 'stats']);
export const DOC_PANEL_KEY = 'qua-reader-doc-panel';

const DEFAULTS: DocPanelPrefs = {
  tab: 'info', // metadata-first preserves the old default; 目录 is one click away
  collapsed: false,
  width: DOC_PANEL_DEFAULT_WIDTH,
};

export function clampPanelWidth(w: number): number {
  if (!Number.isFinite(w)) return DOC_PANEL_DEFAULT_WIDTH;
  return Math.max(DOC_PANEL_MIN_WIDTH, Math.min(DOC_PANEL_MAX_WIDTH, Math.round(w)));
}

interface StorageLike {
  getItem(k: string): string | null;
  setItem(k: string, v: string): void;
}

export function loadDocPanelPrefs(storage: StorageLike | undefined = safeLocalStorage()): DocPanelPrefs {
  if (!storage) return { ...DEFAULTS };
  try {
    const raw = storage.getItem(DOC_PANEL_KEY);
    if (!raw) return { ...DEFAULTS };
    const p = JSON.parse(raw) as Partial<DocPanelPrefs>;
    return {
      tab: typeof p.tab === 'string' && TABS.has(p.tab) ? (p.tab as DocPanelTab) : DEFAULTS.tab,
      collapsed: typeof p.collapsed === 'boolean' ? p.collapsed : DEFAULTS.collapsed,
      width: clampPanelWidth(typeof p.width === 'number' ? p.width : DEFAULTS.width),
    };
  } catch {
    return { ...DEFAULTS };
  }
}

export function saveDocPanelPrefs(p: DocPanelPrefs, storage: StorageLike | undefined = safeLocalStorage()): void {
  if (!storage) return;
  try { storage.setItem(DOC_PANEL_KEY, JSON.stringify(p)); } catch {}
}

function safeLocalStorage(): StorageLike | undefined {
  try { return typeof localStorage !== 'undefined' ? localStorage : undefined; } catch { return undefined; }
}
