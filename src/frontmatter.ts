import { parse as yamlParse, Document as YamlDocument, isSeq, isMap, isScalar } from 'yaml';

const FENCE = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/;

export interface ParsedFile {
  fm: Record<string, unknown> | null;
  body: string;
  /** Original frontmatter text (without fences). Useful for diffing. */
  rawFm: string | null;
}

/**
 * Split a markdown file into frontmatter + body. `fm` is null when the file
 * has no `---` fence. We use the `yaml` package so quirks like inline arrays,
 * block lists, quoted strings and YAML 1.2 booleans/nulls round-trip cleanly.
 */
export function parseFile(text: string): ParsedFile {
  const m = text.match(FENCE);
  if (!m) return { fm: null, body: text, rawFm: null };
  const rawFm = m[1];
  let fm: Record<string, unknown> | null;
  try {
    const parsed = yamlParse(rawFm);
    fm = parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : null;
  } catch {
    fm = null;
  }
  return { fm, body: m[2], rawFm };
}

/**
 * Re-assemble a file from frontmatter + body. We round-trip through a
 * YAML Document so keys keep insertion order, then nudge the AST so the output
 * matches the vault's existing style: inline arrays of scalars stay flow,
 * empty values stay bare (`year:` rather than `year: null`).
 */
export function serializeFile(fm: Record<string, unknown> | null, body: string): string {
  if (!fm) return body;
  const doc = new YamlDocument(fm);
  if (isMap(doc.contents)) {
    for (const item of doc.contents.items) {
      const v = item.value;
      // Inline arrays whose elements are all plain scalars — matches the
      // `themes: [a, b, c]` style that pervades the vault.
      if (isSeq(v) && v.items.every(x => isScalar(x))) {
        v.flow = true;
      }
    }
  }
  const fmText = doc.toString({
    lineWidth: 0,
    nullStr: '',
    flowCollectionPadding: false,
  }).replace(/\n$/, '');
  // parseFile's regex consumes exactly one newline after the closing fence,
  // so whatever leading newline the body still has is the *user-authored*
  // blank line. Concatenate as-is — stripping it here would eat that line.
  return `---\n${fmText}\n---\n${body}`;
}

/** Star-rating → numeric score. `★★★` → 3, `3` → 3, anything else → 0. */
export function ratingScore(r: unknown): number {
  if (typeof r === 'number') return r;
  if (typeof r === 'string') {
    const stars = (r.match(/★/g) || []).length;
    if (stars) return stars;
    const n = parseInt(r, 10);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

/** Normalize a rating value for write-back: always emit `★`-style strings. */
export function ratingToStars(score: number): string | null {
  if (!Number.isFinite(score) || score <= 0) return null;
  return '★'.repeat(Math.max(0, Math.min(5, Math.round(score))));
}
