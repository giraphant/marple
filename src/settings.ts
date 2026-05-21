import type { EntryType, TypeMeta } from './types';
import { TYPES } from './types';
import type { CitationFormat } from './citation';
import type { SortKey, SortDir, SortClause } from './list-sort';

export type FontFamily = 'sans' | 'serif' | 'mono';
export type Theme = 'light' | 'dark' | 'system';

export interface Settings {
  /** When true, all LLM-generated body content (paper/book/author/topic/chapter)
   * becomes editable through the same CodeMirror surface used for notes.
   * Default false — protects against accidental edits to generated material. */
  allowEditLLMBody: boolean;

  /** Editor font family preset. Backed by a fixed stack per choice. */
  fontFamily: FontFamily;
  /** Editor body font size in px. */
  fontSize: number;
  /** Editor line height (unitless). */
  lineHeight: number;

  /** Color theme. 'system' follows prefers-color-scheme. */
  theme: Theme;

  /** User-defined order of object-type rows in the sidebar. If absent or
   * missing some types (e.g. a new type was added since this setting was
   * saved), `orderedTypes()` falls back to TYPES order for the missing
   * ones. */
  typeOrder?: EntryType[];

  /** Default format for the "复制引用" button. Inline forms (en/zh) cover
   * the most common writing case; markdown is the verbose form; title is
   * just the work's title. */
  citationFormat: CitationFormat;

  /** Collapse the leftmost main sidebar to icon-only (~56px). Section
   * labels disappear; rows become square icon-buttons with hover tooltips.
   * Toggled by Cmd+B or the chevron at the sidebar's top. */
  sidebarCollapsed?: boolean;

  /** Legacy single-level sort (QUA-59). Read once to seed `sortClauses` for
   * users upgrading; no longer written. 'default' preserves index order. */
  sortKey?: SortKey;
  sortDir?: SortDir;

  /** Multi-level list sort (QUA-63). Applied in order; empty = index order.
   * Persisted globally so the chosen ordering sticks across sessions. */
  sortClauses?: SortClause[];
}

const DEFAULTS: Settings = {
  allowEditLLMBody: false,
  fontFamily: 'sans',
  fontSize: 16,
  lineHeight: 1.78,
  theme: 'system',
  citationFormat: 'inline-en',
};

export const SETTINGS_KEY = 'qua-reader-settings';

export function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (!raw) return { ...DEFAULTS };
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object') return { ...DEFAULTS, ...parsed };
  } catch {}
  return { ...DEFAULTS };
}

export function saveSettings(s: Settings): void {
  try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(s)); } catch {}
}

/** Resolve a fontFamily preset into a concrete CSS font-family stack. */
export function fontStack(family: FontFamily): string {
  switch (family) {
    case 'serif':
      return '"Songti SC", "STSong", "Iowan Old Style", "Charter", "Hoefler Text", Georgia, serif';
    case 'mono':
      return 'ui-monospace, "SF Mono", SFMono-Regular, "JetBrains Mono", "Menlo", monospace';
    case 'sans':
    default:
      return '"PingFang SC", "PingFang TC", -apple-system, BlinkMacSystemFont, "Helvetica Neue", "Hiragino Sans GB", system-ui, sans-serif';
  }
}

export const FONT_SIZE_OPTIONS = [14, 15, 16, 17, 18] as const;
export const LINE_HEIGHT_OPTIONS = [1.6, 1.78, 1.9] as const;

/** Return TYPES in the user-saved order. Unknown ids in the saved order are
 * skipped (e.g. removed types); new types not in the saved order are appended
 * at the end so they remain discoverable. */
export function orderedTypes(s: Settings): TypeMeta[] {
  const saved = s.typeOrder;
  if (!saved || !Array.isArray(saved) || saved.length === 0) return TYPES;
  const byId = new Map(TYPES.map(t => [t.id, t] as const));
  const out: TypeMeta[] = [];
  const seen = new Set<EntryType>();
  for (const id of saved) {
    const t = byId.get(id);
    if (t && !seen.has(id)) { out.push(t); seen.add(id); }
  }
  for (const t of TYPES) if (!seen.has(t.id)) out.push(t);
  return out;
}
