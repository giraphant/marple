import type { Entry } from './types';

type BibliographicRow = { label: string; value: string };

export interface BibliographicInfo {
  book: Entry | null;
  rows: BibliographicRow[];
}

export function deriveBibliographicInfo(entry: Entry, entries: Entry[]): BibliographicInfo {
  const book = findBookOverview(entry, entries);
  const meta = entry.type === 'chapter-summary' ? (book ?? entry) : entry;
  const rows: BibliographicRow[] = [];

  addBibliographicRow(rows, '中文题名', entry.title_cn, [entry.title]);
  addBibliographicRow(rows, '英文题名', entry.title_en, [entry.title]);
  addBibliographicRow(rows, '出版社', meta.publisher);
  addBibliographicRow(rows, 'ISBN', meta.isbn);
  addBibliographicRow(rows, 'DOI', meta.doi);

  const source = cleanBibliographicText(meta.source);
  const publisher = cleanBibliographicText(meta.publisher);
  if (source && source !== 'book' && !sameBibliographicText(source, publisher)) {
    rows.push({ label: '来源', value: source });
  }

  return { book: entry.type === 'chapter-summary' ? book : null, rows };
}

function findBookOverview(entry: Entry, entries: Entry[]): Entry | null {
  if (entry.type !== 'chapter-summary' || !entry.book) return null;
  const overviewPath = `vault/books/${entry.book}/00-overview.md`;
  return entries.find(e => e.type === 'book-overview' && e.path === overviewPath)
    ?? entries.find(e => e.type === 'book-overview' && e.path.startsWith(`vault/books/${entry.book}/`))
    ?? null;
}

function addBibliographicRow(rows: BibliographicRow[], label: string, raw: unknown, duplicates: unknown[] = []) {
  const value = cleanBibliographicText(raw);
  if (!value) return;
  if (duplicates.some(dup => sameBibliographicText(value, cleanBibliographicText(dup)))) return;
  rows.push({ label, value });
}

function cleanBibliographicText(value: unknown): string | null {
  if (value == null) return null;
  const text = String(value).trim();
  return text === '' ? null : text;
}

function sameBibliographicText(a: unknown, b: unknown): boolean {
  const left = cleanBibliographicText(a)?.toLocaleLowerCase();
  const right = cleanBibliographicText(b)?.toLocaleLowerCase();
  return !!left && !!right && left === right;
}
