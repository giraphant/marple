import type { Entry } from './types';

interface SearchField {
  name: string;
  text: string;
  weight: number;
  fuzzy: boolean;
}

export interface SearchDocument<T extends Entry = Entry> {
  entry: T;
  fields: SearchField[];
}

interface SearchPrepared {
  phrase: string;
  tokens: string[];
}

const FIELD_WEIGHTS = {
  title: 120,
  author: 70,
  book: 62,
  themes: 56,
  topic: 50,
  source: 44,
  year: 36,
  path: 26,
  preview: 18,
  identifier: 10,
};

const TOKEN_SPLIT = /[\s,，;；]+/;
const WORD_SPLIT = /[\s,，;；:：/\\()[\]{}"'“”‘’|*]+/;

function fieldText(v: unknown): string {
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return String(v);
  if (Array.isArray(v)) return v.map(fieldText).filter(Boolean).join(' ');
  return '';
}

function normalize(s: string): string {
  return s
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '');
}

function normalizeForTokenizing(s: string): string {
  return normalize(s).replace(/[-_]+/g, ' ');
}

export function parseSearchQuery(query: string): SearchPrepared {
  const phrase = normalizeForTokenizing(query.trim());
  const tokens = normalize(query)
    .split(TOKEN_SPLIT)
    .map(t => t.trim())
    .filter(Boolean)
    .flatMap(token => isIdentifierLike(token)
      ? [compactIdentifier(token)]
      : normalizeForTokenizing(token).split(TOKEN_SPLIT).filter(Boolean)
    )
    .filter(Boolean);
  return { phrase, tokens };
}

export function rankEntry(entry: Entry, query: string | SearchPrepared): number {
  return rankSearchDocument({ entry, fields: entryFields(entry) }, query);
}

export function buildSearchIndex<T extends Entry>(entries: T[]): SearchDocument<T>[] {
  return entries.map(entry => ({ entry, fields: entryFields(entry) }));
}

export function rankSearchDocument(
  doc: SearchDocument,
  query: string | SearchPrepared,
): number {
  const prepared = typeof query === 'string' ? parseSearchQuery(query) : query;
  if (prepared.tokens.length === 0) return 0;

  let total = 0;
  const matchedFieldNames = new Set<string>();

  for (const token of prepared.tokens) {
    const allowIdentifier = shouldSearchIdentifier(token);
    let best = 0;
    let bestField = '';

    for (const field of doc.fields) {
      if (!shouldSearchField(token, field, allowIdentifier)) continue;
      const score = scoreTokenInField(token, field);
      if (score > best) {
        best = score;
        bestField = field.name;
      }
    }

    if (best <= 0) return 0;
    total += best;
    if (bestField) matchedFieldNames.add(bestField);
  }

  total += scorePhrase(prepared.phrase, doc.fields);

  if (matchedFieldNames.size === 1) total += 18;
  if (total > 0) total += (doc.entry.rating_score || 0) * 3;
  return total;
}

export function searchEntries<T extends Entry>(entries: T[], query: string): Array<{ entry: T; score: number }> {
  return searchDocuments(buildSearchIndex(entries), query);
}

export function searchDocuments<T extends Entry>(
  documents: SearchDocument<T>[],
  query: string,
): Array<{ entry: T; score: number }> {
  const prepared = parseSearchQuery(query);
  if (prepared.tokens.length === 0) return [];
  const out: Array<{ entry: T; score: number }> = [];
  for (const doc of documents) {
    const score = rankSearchDocument(doc, prepared);
    if (score > 0) out.push({ entry: doc.entry, score });
  }
  out.sort((a, b) => b.score - a.score);
  return out;
}

function entryFields(entry: Entry): SearchField[] {
  const loose = entry as Entry & Record<string, unknown>;
  const identifierText = [
    fieldText(entry.doi),
    fieldText(loose.isbn),
    fieldText(loose.issn),
    fieldText(loose.jstor),
    fieldText(loose.pmid),
    fieldText(loose.openalex),
  ].filter(Boolean).join(' ');

  return [
    { name: 'title', text: fieldText(entry.title), weight: FIELD_WEIGHTS.title, fuzzy: true },
    { name: 'author', text: fieldText(entry.author), weight: FIELD_WEIGHTS.author, fuzzy: true },
    { name: 'book', text: fieldText(entry.book), weight: FIELD_WEIGHTS.book, fuzzy: true },
    { name: 'themes', text: fieldText(entry.themes), weight: FIELD_WEIGHTS.themes, fuzzy: true },
    { name: 'topic', text: fieldText(entry.topic), weight: FIELD_WEIGHTS.topic, fuzzy: true },
    { name: 'source', text: fieldText(entry.source), weight: FIELD_WEIGHTS.source, fuzzy: true },
    { name: 'year', text: fieldText(entry.year), weight: FIELD_WEIGHTS.year, fuzzy: false },
    { name: 'path', text: fieldText(entry.path), weight: FIELD_WEIGHTS.path, fuzzy: false },
    { name: 'preview', text: fieldText(entry.preview), weight: FIELD_WEIGHTS.preview, fuzzy: false },
    {
      name: 'identifier',
      text: `${identifierText} ${compactIdentifier(identifierText)}`,
      weight: FIELD_WEIGHTS.identifier,
      fuzzy: false,
    },
  ].map(field => ({ ...field, text: normalizeForTokenizing(field.text) }));
}

function scorePhrase(phrase: string, fields: SearchField[]): number {
  if (!phrase || phrase.length < 3 || !phrase.includes(' ')) return 0;
  let best = 0;
  for (const field of fields) {
    if (field.name === 'identifier') continue;
    const idx = normalize(field.text).indexOf(phrase);
    if (idx < 0) continue;
    best = Math.max(best, field.weight * 2 + positionBoost(idx));
  }
  return best;
}

function scoreTokenInField(token: string, field: SearchField): number {
  if (!token) return 0;
  const text = field.text;
  if (!text) return 0;

  const idx = text.indexOf(token);
  if (idx >= 0) {
    const boundary = isBoundaryHit(text, token, idx);
    const exactWord = boundary && isBoundaryAfter(text, idx + token.length);
    const factor = exactWord ? 4 : boundary ? 3 : 1.7;
    return field.weight * factor + positionBoost(idx);
  }

  if (!field.fuzzy || !canFuzzy(token)) return 0;
  const words = text.split(WORD_SPLIT).filter(Boolean);
  let best = 0;
  for (const word of words) {
    if (!canCompareFuzzy(token, word)) continue;
    const distance = levenshteinWithin(token, word, fuzzyLimit(token));
    if (distance == null) continue;
    const factor = distance === 1 ? 1.2 : 0.85;
    best = Math.max(best, field.weight * factor);
  }
  return best;
}

function shouldSearchField(token: string, field: SearchField, allowIdentifier: boolean): boolean {
  if (field.name === 'identifier') return allowIdentifier;
  if (!isShortNumericToken(token)) return true;
  return field.name === 'title' || field.name === 'year';
}

function shouldSearchIdentifier(token: string): boolean {
  if (token.length >= 8 && /[0-9]/.test(token)) return true;
  if (/^10\.\d{4,9}\//.test(token)) return true;
  if (/[/.]/.test(token) && token.length >= 6) return true;
  if (/^(isbn|doi|issn|pmid|jstor)/.test(token)) return true;
  return false;
}

function isShortNumericToken(token: string): boolean {
  return /^[0-9]+$/.test(token) && token.length < 5;
}

function isIdentifierLike(token: string): boolean {
  if (/^10\.\d{4,9}\//.test(token)) return true;
  if (/^(isbn|doi|issn|pmid|jstor)/.test(token)) return true;
  return /[0-9]/.test(token) && /[-/.]/.test(token) && compactIdentifier(token).length >= 8;
}

function compactIdentifier(s: string): string {
  return normalize(s).replace(/[^a-z0-9]+/g, '');
}

function canFuzzy(token: string): boolean {
  return token.length >= 5 && /^[a-z0-9]+$/.test(token) && /[a-z]/.test(token);
}

function canCompareFuzzy(token: string, word: string): boolean {
  if (!/^[a-z0-9]+$/.test(word)) return false;
  const limit = fuzzyLimit(token);
  return Math.abs(token.length - word.length) <= limit;
}

function fuzzyLimit(token: string): number {
  return token.length >= 8 ? 2 : 1;
}

function positionBoost(idx: number): number {
  return Math.max(0, 35 - Math.min(idx, 35));
}

function isBoundaryHit(text: string, token: string, idx: number): boolean {
  return idx === 0 || isBoundaryBefore(text, idx) || text.slice(idx - 1, idx + token.length).includes(` ${token}`);
}

function isBoundaryBefore(text: string, idx: number): boolean {
  return idx <= 0 || !/[a-z0-9]/.test(text[idx - 1] ?? '');
}

function isBoundaryAfter(text: string, idx: number): boolean {
  return idx >= text.length || !/[a-z0-9]/.test(text[idx] ?? '');
}

function levenshteinWithin(a: string, b: string, max: number): number | null {
  if (Math.abs(a.length - b.length) > max) return null;
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);

  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    let rowMin = cur[0];
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      const next = Math.min(
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + cost,
      );
      cur[j] = next;
      rowMin = Math.min(rowMin, next);
    }
    if (rowMin > max) return null;
    prev = cur;
  }

  const distance = prev[b.length];
  return distance <= max ? distance : null;
}
