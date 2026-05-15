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
}

const DEFAULTS: Settings = {
  allowEditLLMBody: false,
  fontFamily: 'sans',
  fontSize: 16,
  lineHeight: 1.78,
  theme: 'system',
};

const KEY = 'qua-reader-settings';

export function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return { ...DEFAULTS };
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object') return { ...DEFAULTS, ...parsed };
  } catch {}
  return { ...DEFAULTS };
}

export function saveSettings(s: Settings): void {
  try { localStorage.setItem(KEY, JSON.stringify(s)); } catch {}
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
