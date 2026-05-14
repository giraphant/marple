import type { Entry } from './types';

const WIKI_RE = /\[\[([^\]|\n]+?)(?:\|([^\]\n]+?))?\]\]/g;

function bookSlugOf(entry: Entry): string | null {
  const m = entry.path.match(/^vault\/books\/([^/]+)\//);
  return m ? m[1] : null;
}

export function buildWikiIndex(entries: Entry[]): Map<string, Entry> {
  const m = new Map<string, Entry>();
  const put = (k: string | null | undefined, v: Entry) => {
    if (!k) return;
    if (!m.has(k)) m.set(k, v);
    const lk = k.toLowerCase();
    if (!m.has(lk)) m.set(lk, v);
  };
  for (const e of entries) {
    const noExt = e.path.replace(/^vault\//, '').replace(/\.md$/, '');
    put(noExt, e);
    const base = noExt.split('/').pop()!;
    put(base, e);
    if (e.type === 'chapter-summary' && e.book) put(`${e.book}/${base}`, e);
    if (e.type === 'book-overview') {
      const slug = bookSlugOf(e);
      if (slug) put(slug, e);
    }
  }
  return m;
}

export function resolveWikilinks(md: string, wikiIndex: Map<string, Entry>): string {
  return md.replace(WIKI_RE, (_, target: string, display?: string) => {
    const t = target.trim();
    const baseTarget = t.split('#')[0];
    const txt = (display || baseTarget.split('/').pop() || '').trim();
    const escTxt = txt
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
    const found = wikiIndex.get(baseTarget) || wikiIndex.get(baseTarget.toLowerCase());
    if (found) {
      return `<a href="#" data-wiki="${found.path}" class="wiki-link">${escTxt}</a>`;
    }
    return `<span class="wiki-broken" title="未找到: ${t.replace(/"/g, '&quot;')}">${escTxt}</span>`;
  });
}

export { bookSlugOf };

export function splitAuthors(s: string | null | undefined): string[] {
  if (!s) return [];
  return s.split(/,| & | and /i).map(x => x.trim()).filter(Boolean);
}
