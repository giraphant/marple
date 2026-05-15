#!/usr/bin/env node
// Scan vault/ for .md files, parse frontmatter with the `yaml` package,
// emit reader/data/index.json (one row per file, with a `preview` derived
// from the first body paragraph).

import { readdir, readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse as yamlParse } from 'yaml';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '../..');
const VAULT = path.join(ROOT, 'vault');
const SOURCES = path.join(ROOT, 'sources');
const OUT = path.resolve(__dirname, '../data');

/** Scan sources/ for top-level .pdf files; return a set of filename stems. */
async function loadSourceSlugs() {
  const slugs = new Set();
  try {
    const files = await readdir(SOURCES);
    for (const f of files) {
      if (/\.pdf$/i.test(f)) slugs.add(f.slice(0, -4));
    }
  } catch {}
  return slugs;
}

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

const FENCE = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/;

function parseFile(text) {
  const m = text.match(FENCE);
  if (!m) return { fm: null, body: text };
  let fm = null;
  try {
    const parsed = yamlParse(m[1]);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) fm = parsed;
  } catch {
    fm = null;
  }
  return { fm, body: m[2] };
}

function firstParagraph(body) {
  const paras = body.split(/\n\n+/);
  for (const p of paras) {
    const t = p.trim();
    if (!t) continue;
    if (t.startsWith('#') || t.startsWith('---')) continue;
    if (t.startsWith('**') && t.endsWith('**') && t.length < 80) continue;
    return t.replace(/\s+/g, ' ').slice(0, 320);
  }
  return '';
}

// Star-rating → numeric score. Supports `★★★`, `★★★★ (4)`, plain `3`.
function ratingScore(r) {
  if (typeof r === 'number') return r;
  if (typeof r === 'string') {
    const stars = (r.match(/★/g) || []).length;
    if (stars) return stars;
    const n = parseInt(r, 10);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

function stripWiki(s) {
  if (typeof s !== 'string') return s;
  return s.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, slug, disp) => (disp || slug).trim());
}

function flattenAuthor(v) {
  if (v == null) return null;
  if (Array.isArray(v)) return v.map(stripWiki).filter(Boolean).join(', ');
  return stripWiki(v);
}

// Collapse the long tail of type aliases observed in the vault.
const TYPE_ALIAS = {
  paper: 'paper-analysis',
  'paper-summary': 'paper-analysis',
  'article-analysis': 'paper-analysis',
  'journal-article': 'paper-analysis',
  'journal-article-analysis': 'paper-analysis',
  author: 'author-profile',
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
  if (!t || t === 'A') return null;
  return TYPE_ALIAS[t] || t;
}

(async () => {
  console.log('scanning', VAULT);
  const files = await walk(VAULT);
  console.log(`found ${files.length} md files`);

  const sourceSlugs = await loadSourceSlugs();
  if (sourceSlugs.size > 0) console.log(`sources/ has ${sourceSlugs.size} PDFs`);

  const entries = [];
  let bad = 0;
  for (const f of files) {
    const [text, fStat] = await Promise.all([
      readFile(f, 'utf8'),
      stat(f).catch(() => null),
    ]);
    const { fm, body } = parseFile(text);
    if (!fm || !fm.type) { if (fm) bad++; continue; }
    const type = canonicalType(fm.type);
    if (!type) continue;
    const rel = path.relative(ROOT, f).split(path.sep).join('/');
    const bookMatch = type === 'chapter-summary' && rel.match(/^vault\/books\/([^/]+)\//);

    // PDF lookup: papers use their filename stem; book overviews use the
    // containing book-directory slug.
    let pdf_slug = null;
    if (type === 'paper-analysis') {
      pdf_slug = path.basename(f, '.md');
    } else if (type === 'book-overview') {
      const m = rel.match(/^vault\/books\/([^/]+)\//);
      pdf_slug = m ? m[1] : null;
    }
    const has_pdf = pdf_slug ? sourceSlugs.has(pdf_slug) : false;

    entries.push({
      path: rel,
      type,
      book: bookMatch ? bookMatch[1] : null,
      title: stripWiki(fm.title || fm.name) || null,
      author: flattenAuthor(fm.author ?? fm.authors),
      year: fm.year ?? null,
      rating: fm.rating || null,
      rating_score: ratingScore(fm.rating),
      themes: Array.isArray(fm.themes) ? fm.themes : null,
      topic: fm.topic || null,
      source: fm.source || null,
      doi: fm.doi || null,
      chapters_analyzed: fm.chapters_analyzed ?? null,
      annotates: fm.annotates || null,
      created: fm.created != null ? String(fm.created) : null,
      pdf_slug,
      has_pdf,
      mtime: fStat ? Math.floor(fStat.mtimeMs) : null,
      preview: firstParagraph(body),
    });
  }

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
  if (bad > 0) console.log(`skipped ${bad} files with frontmatter but no usable type`);
})();
