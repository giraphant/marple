import type { Entry } from './types';

type BibliographicRow = { label: string; value: string; href?: string };

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
  addBibliographicRow(rows, '图书号', meta.isbn);
  addBibliographicRow(rows, 'DOI', meta.doi);

  const translationTitle = cleanBibliographicText(meta.translation_title_cn ?? entry.translation_title_cn);
  const translationHref = cleanBibliographicText(meta.translation_douban_url ?? entry.translation_douban_url);
  if (translationTitle || translationHref) {
    rows.push({
      label: '中文版',
      value: translationTitle ?? '豆瓣条目',
      ...(translationHref ? { href: translationHref } : {}),
    });
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
