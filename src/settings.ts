export interface Settings {
  /** When true, all LLM-generated body content (paper/book/author/topic/chapter)
   * becomes editable through the same CodeMirror surface used for notes.
   * Default false — protects against accidental edits to generated material. */
  allowEditLLMBody: boolean;
}

const DEFAULTS: Settings = { allowEditLLMBody: false };
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
