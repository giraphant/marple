#!/usr/bin/env node
// Scan vault/ for .md files, parse frontmatter, emit reader/data/index.json.
// No npm deps — uses a small hand-rolled YAML-ish parser sized to the frontmatter
// shapes actually present in the vault (key: scalar | quoted | inline-array | block-list).

import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '../..');
const VAULT = path.join(ROOT, 'vault');
const OUT = path.resolve(__dirname, '../data');

async function walk(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const out = [];
  for (const e of entries) {
    if (e.name.startsWith('.')) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...await walk(p));
    else if (e.name.endsWith('.md')) out.push(p);
  }
  return out;
}

function stripQuotes(s) {
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  return s;
}

function parseValue(v) {
  v = v.trim();
  if (v === '' || v === '~' || v === 'null') return null;
  if (v.startsWith('[') && v.endsWith(']')) {
    const inner = v.slice(1, -1).trim();
    if (!inner) return [];
    return inner.split(',').map(s => stripQuotes(s.trim())).filter(Boolean);
  }
  if (/^-?\d+$/.test(v)) return Number(v);
  if (/^-?\d+\.\d+$/.test(v)) return Number(v);
  return stripQuotes(v);
}

function parseFrontmatter(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { fm: null, body: text };
  const fm = {};
  const lines = m[1].split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const kv = line.match(/^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.*)$/);
    if (!kv) continue;
    const key = kv[1];
    const raw = kv[2];
    if (raw.trim() === '') {
      // Possibly a block list.
      const items = [];
      while (i + 1 < lines.length && /^\s+-\s+/.test(lines[i + 1])) {
        items.push(stripQuotes(lines[++i].replace(/^\s+-\s+/, '').trim()));
      }
      fm[key] = items.length ? items : null;
    } else {
      fm[key] = parseValue(raw);
    }
  }
  return { fm, body: m[2] };
}

function firstParagraph(body) {
  // Skip leading headings/blanks, grab first non-empty paragraph, cap length.
  const paras = body.split(/\n\n+/);
  for (const p of paras) {
    const t = p.trim();
    if (!t) continue;
    if (t.startsWith('#') || t.startsWith('---')) continue;
    if (t.startsWith('**') && t.endsWith('**') && t.length < 80) continue; // bold one-liner labels
    return t.replace(/\s+/g, ' ').slice(0, 320);
  }
  return '';
}

function ratingScore(r) {
  if (typeof r !== 'string') return 0;
  return (r.match(/★/g) || []).length;
}

function stripWiki(s) {
  // [[slug|Display]] → Display, [[slug]] → slug
  if (typeof s !== 'string') return s;
  return s.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, slug, disp) => (disp || slug).trim());
}

function flattenAuthor(v) {
  if (v == null) return null;
  if (Array.isArray(v)) return v.map(stripWiki).filter(Boolean).join(', ');
  return stripWiki(v);
}

// Collapse the long tail of type aliases observed in the vault into a
// canonical set the UI knows about.
const TYPE_ALIAS = {
  paper: 'paper-analysis',
  'paper-summary': 'paper-analysis',
  'article-analysis': 'paper-analysis',
  'journal-article': 'paper-analysis',
  'journal-article-analysis': 'paper-analysis',
  book: 'book-overview',
  'book-analysis': 'book-overview',
  monograph: 'book-overview',
  'monograph-analysis': 'book-overview',
  overview: 'book-overview',
  chapter: 'chapter-summary',
  'book-chapter': 'chapter-summary',
  book_chapter: 'chapter-summary',
  'chapter-analysis': 'chapter-summary',
  'journal-synthesis': 'topic-synthesis',
  'snowball-synthesis': 'topic-synthesis',
  'citation-snowball-synthesis': 'topic-synthesis',
  'reading-list': 'topic-synthesis',
  'research-note': 'topic-synthesis',
  'concept-note': 'topic-synthesis',
};
function canonicalType(t) {
  if (!t || t === 'A') return null; // 'A' = malformed frontmatter in a handful of files
  return TYPE_ALIAS[t] || t;
}

(async () => {
  console.log('scanning', VAULT);
  const files = await walk(VAULT);
  console.log(`found ${files.length} md files`);

  const entries = [];
  for (const f of files) {
    const text = await readFile(f, 'utf8');
    const { fm, body } = parseFrontmatter(text);
    if (!fm || !fm.type) continue;
    const type = canonicalType(fm.type);
    if (!type) continue;
    const rel = path.relative(ROOT, f).split(path.sep).join('/');
    // Derive a parent slug for chapters so the UI can group them under their book.
    const bookMatch = type === 'chapter-summary' && rel.match(/^vault\/books\/([^/]+)\//);
    entries.push({
      path: rel,
      type,
      book: bookMatch ? bookMatch[1] : null,
      title: stripWiki(fm.title) || null,
      author: flattenAuthor(fm.author),
      year: fm.year ?? null,
      rating: fm.rating || null,
      rating_score: ratingScore(fm.rating),
      themes: Array.isArray(fm.themes) ? fm.themes : null,
      topic: fm.topic || null,
      source: fm.source || null,
      doi: fm.doi || null,
      chapters_analyzed: fm.chapters_analyzed ?? null,
      preview: firstParagraph(body),
    });
  }

  // Stable sort: by type then by rating desc then by title.
  entries.sort((a, b) => {
    if (a.type !== b.type) return a.type.localeCompare(b.type);
    if (a.rating_score !== b.rating_score) return b.rating_score - a.rating_score;
    return (a.title || a.path).localeCompare(b.title || b.path);
  });

  await mkdir(OUT, { recursive: true });
  await writeFile(path.join(OUT, 'index.json'), JSON.stringify(entries));

  const byType = {};
  for (const e of entries) byType[e.type] = (byType[e.type] || 0) + 1;
  console.log('wrote', entries.length, 'entries →', path.relative(ROOT, path.join(OUT, 'index.json')));
  console.log('by type:', byType);
})();
