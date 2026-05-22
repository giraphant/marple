export type MatchCandidate = {
  original_title?: string;
  title_cn?: string;
  authors?: string[];
  year?: number;
  isbn?: string;
};

export type OriginalBook = {
  title: string;
  authors?: string[];
  year?: number;
  isbn13?: string;
};

export type MatchResult = {
  score: number;
  confidence: 'high' | 'medium' | 'low' | 'none';
  signals: string[];
};

export function scoreCandidate(candidate: MatchCandidate, original: OriginalBook): MatchResult {
  let score = 0;
  const signals: string[] = [];

  const candidateTitle = normaliseTitle(candidate.original_title);
  const originalTitle = normaliseTitle(original.title);
  if (candidateTitle && originalTitle) {
    if (candidateTitle === originalTitle) {
      score += 50;
      signals.push('original_title exact match +50');
    } else if (candidateTitle.includes(originalTitle) || originalTitle.includes(candidateTitle)) {
      score += 30;
      signals.push('original_title contains match +30');
    }
  }

  const candidateSurnames = surnameSet(candidate.authors);
  const originalSurnames = surnameSet(original.authors);
  if (intersects(candidateSurnames, originalSurnames)) {
    score += 20;
    signals.push('author surname match +20');
  }

  const candidateYear = asYear(candidate.year);
  const originalYear = asYear(original.year);
  if (candidateYear != null && originalYear != null) {
    const delta = Math.abs(candidateYear - originalYear);
    if (delta <= 5) {
      score += 10;
      signals.push('year within 5 years +10');
    } else if (delta <= 10) {
      score += 5;
      signals.push('year within 10 years +5');
    }
  }

  if (isChinesePublisherIsbn(candidate.isbn)) {
    score += 15;
    signals.push('Chinese publisher ISBN agency +15');
  }

  if (!candidate.original_title?.trim()) {
    score -= 20;
    signals.push('missing original_title -20');
  }

  return {
    score,
    confidence: confidenceFor(score),
    signals,
  };
}

function normaliseTitle(value: string | undefined): string {
  return (value ?? '')
    .normalize('NFKC')
    .replace(/[\p{P}\p{S}]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .toLocaleLowerCase();
}

function titleTokens(value: string | undefined): Set<string> {
  return new Set(normaliseTitle(value).split(' ').filter(w => w.length > 1));
}

function jaccard(a: Set<string>, b: Set<string>): number {
  if (!a.size || !b.size) return 0;
  let inter = 0;
  for (const x of a) if (b.has(x)) inter++;
  return inter / (a.size + b.size - inter);
}

/**
 * 0..1 similarity between two book titles. 1 when one normalised title contains
 * the other (handles subtitles); otherwise the larger of full-title and
 * title-head (pre-colon) Jaccard token overlap.
 */
export function titleAffinity(a: string | undefined, b: string | undefined): number {
  const na = normaliseTitle(a);
  const nb = normaliseTitle(b);
  if (!na || !nb) return 0;
  if (na === nb || na.includes(nb) || nb.includes(na)) return 1;
  const full = jaccard(titleTokens(a), titleTokens(b));
  const head = jaccard(titleTokens(a?.split(/[:：]/)[0]), titleTokens(b?.split(/[:：]/)[0]));
  return Math.max(full, head);
}

export type CorpusBook = { slug: string; title: string };

/**
 * Find the corpus book whose title best matches `originalTitle`. Used to detect
 * cross-book mis-association: a Douban search for book X often returns the
 * Chinese edition of a *different* book Y by the same author, whose `原作名`
 * (originalTitle) then matches Y, not X. Returns the best owner or null.
 */
export function resolveOwner(
  originalTitle: string | undefined,
  corpus: CorpusBook[],
): { slug: string; score: number } | null {
  let best: { slug: string; score: number } | null = null;
  for (const book of corpus) {
    const score = titleAffinity(originalTitle, book.title);
    if (!best || score > best.score) best = { slug: book.slug, score };
  }
  return best && best.score > 0 ? best : null;
}

function surnameSet(authors: string[] | undefined): Set<string> {
  const out = new Set<string>();
  for (const author of authors ?? []) {
    const surname = authorSurname(author);
    if (surname) out.add(surname);
  }
  return out;
}

function authorSurname(author: string): string | null {
  const cleaned = author
    .normalize('NFKC')
    .replace(/[\p{P}\p{S}]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .toLocaleLowerCase();
  if (!cleaned) return null;
  const parts = cleaned.split(' ').filter(Boolean);
  return parts.at(-1) ?? null;
}

function intersects(left: Set<string>, right: Set<string>): boolean {
  if (!left.size || !right.size) return false;
  for (const item of left) {
    if (right.has(item)) return true;
  }
  return false;
}

function asYear(value: number | undefined): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null;
}

// ISBN agency prefixes for Chinese-language editions: mainland (978-7),
// Taiwan (978-957 / 978-986), Hong Kong (978-988 / 978-962). Mirrors the
// upstream Douban adapter's _ZH_ISBN_PREFIXES so the matcher agrees with
// how candidates were filtered at search time.
const ZH_ISBN_PREFIXES = ['9787', '978957', '978986', '978988', '978962'];

function isChinesePublisherIsbn(value: string | undefined): boolean {
  const digits = (value ?? '').replace(/\D/g, '');
  return ZH_ISBN_PREFIXES.some(prefix => digits.startsWith(prefix));
}

function confidenceFor(score: number): MatchResult['confidence'] {
  if (score >= 60) return 'high';
  if (score >= 35) return 'medium';
  if (score >= 10) return 'low';
  return 'none';
}

export type Routing = 'write' | 'review' | 'skip';

/**
 * Association policy. `high` is confident enough to write into frontmatter
 * automatically; `medium` and `low` go to a human review queue (the cached
 * candidates were already found by searching for this exact book, so a
 * borderline match is more likely the right translation than noise); only a
 * `none` (no-signal) match is dropped.
 */
export function routeByConfidence(confidence: MatchResult['confidence']): Routing {
  if (confidence === 'high') return 'write';
  if (confidence === 'medium' || confidence === 'low') return 'review';
  return 'skip';
}
