/**
 * QUA-57: document statistics for the 统计 tab.
 *
 * `words` is CJK-aware: each CJK ideograph counts as one word, and runs of
 * Latin/digits count as one word each (so "技术物 X" → 4). Reading time uses a
 * single blended rate over that word count.
 */

export interface DocStats {
  chars: number;
  charsNoSpace: number;
  words: number;
  paragraphs: number;
  /** Estimated reading time, whole minutes (>= 1 when there's any content). */
  minutes: number;
}

const CJK_RE = /[㐀-䶿一-鿿豈-﫿぀-ヿ]/gu;
const LATIN_RUN_RE = /[A-Za-z0-9À-ɏ]+/g;
const WORDS_PER_MINUTE = 300;

export function countWords(body: string): number {
  const cjk = (body.match(CJK_RE) ?? []).length;
  const latin = (body.match(LATIN_RUN_RE) ?? []).length;
  return cjk + latin;
}

export function computeDocStats(body: string): DocStats {
  const chars = [...body].length;
  const charsNoSpace = [...body.replace(/\s/g, '')].length;
  const words = countWords(body);
  const paragraphs = body
    .split(/\n\s*\n/)
    .map(s => s.trim())
    .filter(Boolean).length;
  const minutes = words > 0 ? Math.max(1, Math.round(words / WORDS_PER_MINUTE)) : 0;
  return { chars, charsNoSpace, words, paragraphs, minutes };
}
