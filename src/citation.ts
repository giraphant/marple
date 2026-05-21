import type { Entry } from './types';
import { splitAuthors } from './wiki';

export type CitationFormat = 'inline-en' | 'inline-zh' | 'title' | 'markdown';

export const CITATION_FORMATS: { id: CitationFormat; label: string; hint: string; example: string }[] = [
  { id: 'inline-en', label: '夹注 (英文)', hint: '括号 + 半角逗号',  example: '(Clark, 1998)' },
  { id: 'inline-zh', label: '夹注 (中文)', hint: '全角括号 + 全角逗号', example: '（Clark，1998）' },
  { id: 'title',     label: '标题',       hint: '纯书 / 文章名',   example: 'Being There' },
  { id: 'markdown',  label: '文献目录',   hint: '作者 + 年份 + 标题 + 来源', example: 'Clark (1998). *Being There*. MIT Press.' },
];

/** Extract the surname from a single author string.
 *  - "Last, First"    → "Last"
 *  - Pure CJK chars   → as-is (Chinese / Japanese / Korean usually 1–4 chars)
 *  - "First Last"     → last whitespace-separated token
 *  - "First M. Last"  → "Last"
 */
function lastname(raw: string): string {
  const name = raw.trim();
  if (!name) return '';
  if (name.includes(',')) return name.split(',')[0].trim();
  if (/^[一-鿿぀-ゟ゠-ヿ]+$/.test(name)) return name;
  const parts = name.split(/\s+/).filter(Boolean);
  return parts[parts.length - 1] ?? name;
}

/** Build an "Author / Author & Author / Author et al." string for inline use. */
function authorsInline(rawAuthor: string | null | undefined, style: 'en' | 'zh'): string {
  const list = splitAuthors(rawAuthor).map(lastname).filter(Boolean);
  if (list.length === 0) return '';
  if (list.length === 1) return list[0];
  if (list.length === 2) return style === 'zh' ? `${list[0]}、${list[1]}` : `${list[0]} & ${list[1]}`;
  return style === 'zh' ? `${list[0]} 等` : `${list[0]} et al.`;
}

/** Render an entry as a citation string per format. Returns empty string when
 *  required fields are missing (callers decide whether to surface an error). */
export function buildCitation(entry: Entry, format: CitationFormat): string {
  const author = entry.author?.trim() || '';
  const year = entry.year != null ? String(entry.year).trim() : '';
  const title = entry.title?.trim() || '';
  const source = entry.source?.trim() || '';
  const doi = entry.doi?.trim() || '';

  switch (format) {
    case 'inline-en': {
      const a = authorsInline(author, 'en');
      if (!a && !year) return '';
      if (a && year) return `(${a}, ${year})`;
      if (a)         return `(${a})`;
      return `(${year})`;
    }
    case 'inline-zh': {
      const a = authorsInline(author, 'zh');
      if (!a && !year) return '';
      if (a && year) return `（${a}，${year}）`;
      if (a)         return `（${a}）`;
      return `（${year}）`;
    }
    case 'title':
      return title;
    case 'markdown':
    default: {
      const parts: string[] = [];
      if (author && year)      parts.push(`${author} (${year}).`);
      else if (author)         parts.push(`${author}.`);
      else if (year)           parts.push(`(${year}).`);
      if (title)               parts.push(`*${title}*.`);
      if (source)              parts.push(`${source}.`);
      if (doi)                 parts.push(`https://doi.org/${doi}`);
      return parts.join(' ').replace(/\s+/g, ' ').trim();
    }
  }
}
