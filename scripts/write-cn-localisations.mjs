#!/usr/bin/env node
import { promises as fs } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';
import * as YAML from 'yaml';
import { readerRoot, workspaceRoot } from './workspace-root.mjs';

// repoRoot = the content workspace (vault/books and .quasi/localise live there);
// READER_ROOT = this marple repo (its src/*.ts matcher modules).
const repoRoot = workspaceRoot();
const READER_ROOT = readerRoot();
const cachePath = path.join(repoRoot, '.quasi/localise/cndouban.json');
const reviewPath = path.join(repoRoot, '.quasi/localise/cn-review.json');
const booksRoot = path.join(repoRoot, 'vault/books');
const force = process.argv.includes('--force');
const dryRun = process.argv.includes('--dry-run');

async function main() {
  if (!await exists(cachePath)) {
    console.log('No .quasi/localise/cndouban.json found; nothing to write. Populate the localisation cache first.');
    return;
  }

  const [{ scoreCandidate, resolveOwner, titleAffinity }, { applyZhLocalisation }] = await Promise.all([
    loadTsModule('src/cn-matcher.ts'),
    loadTsModule('src/cn-localise.ts'),
  ]);
  const cache = await readJson(cachePath);
  const overviews = await loadBookOverviews();
  const corpus = overviews.all
    .map(o => ({ slug: o.slug, title: textOrUndefined(o.fm.title) }))
    .filter(b => b.slug && b.title);
  const workItems = cacheWorkItems(cache);
  const unmatched = [];
  const misassociated = [];
  // A given Chinese edition (douban subject) translates ONE work; never attach it
  // to two book overviews (e.g. two kept English translations of the same book).
  // Seed with editions already present so re-runs stay idempotent.
  const seenDoubanIds = new Set();
  for (const o of overviews.all) {
    for (const id of zhDoubanIds(o.fm)) seenDoubanIds.add(id);
  }

  let associated = 0;
  let skippedNone = 0;
  let skippedMisassoc = 0;
  let skippedExisting = 0;
  let skippedUnmatched = 0;

  for (const item of workItems) {
    const candidates = candidateRecords(item.entry, cache);
    let overview = resolveOverview(item, overviews);
    // ISBN/slug/path fallback failed (often the cache key is a different edition's
    // ISBN than the vault). Resolve by the candidate's 原作名 → owning book title.
    if (!overview && candidates.length) {
      for (const raw of candidates) {
        const owner = resolveOwner(matchCandidateFromRecord(raw).original_title, corpus);
        if (owner && owner.score >= 0.6) {
          const byTitle = overviews.bySlug.get(owner.slug);
          if (byTitle) { overview = byTitle; break; }
        }
      }
    }
    if (!overview) {
      skippedUnmatched += 1;
      unmatched.push({ key: item.key, isbn: item.isbn, slug: item.slug ?? null });
      continue;
    }

    const original = originalFromFrontmatter(overview.fm);
    if (!original) {
      skippedUnmatched += 1;
      unmatched.push({ key: item.key, path: overview.relPath, reason: 'missing original title' });
      continue;
    }

    if (!candidates.length) {
      skippedNone += 1;
      continue;
    }

    const scored = [];
    for (const raw of candidates) {
      const candidate = matchCandidateFromRecord(raw);
      // A real Chinese edition must have a Chinese (CJK) title. Some found
      // entries carry candidates whose title failed to scrape (English or empty)
      // — writing those produces a useless "中文版: The Parasite" row.
      if (!hasCjk(candidate.title_cn)) continue;
      const selfAffinity = titleAffinity(candidate.original_title, original.title);
      // Cross-book guard: a Douban search for this book often returns the Chinese
      // edition of a *different* book by the same author. If the candidate's 原作名
      // names another vault book better than this one, attribute it there and skip.
      const owner = resolveOwner(candidate.original_title, corpus);
      if (owner && owner.slug !== overview.slug && owner.score >= 0.6 && owner.score > selfAffinity) {
        skippedMisassoc += 1;
        misassociated.push({
          cached_under: overview.slug,
          belongs_to: owner.slug,
          original_title: candidate.original_title,
          candidate: localisationFromRecord(raw, candidate),
        });
        continue;
      }
      scored.push({ raw, candidate, selfAffinity, result: scoreCandidate(candidate, original) });
    }
    if (!scored.length) continue; // every candidate was mis-associated to another book

    // Each work item is a status=found entry the agent vouched per original book,
    // so the best non-conflicted candidate is the translation. Prefer the one whose
    // 原作名 matches this book's title, then by matcher score, then Douban ratings.
    scored.sort((a, b) =>
      (b.selfAffinity - a.selfAffinity)
      || (b.result.score - a.result.score)
      || ((parseInteger(b.raw.ratings_count) ?? 0) - (parseInteger(a.raw.ratings_count) ?? 0)));
    // Skip any candidate edition already attached to another book (same work).
    const best = scored.find(s => !seenDoubanIds.has(candidateDoubanId(s.raw)));
    if (!best) { skippedExisting += 1; continue; }
    const localisation = localisationFromRecord(best.raw, best.candidate);
    const nextText = applyZhLocalisation(YAML, overview.text, localisation, { force });
    if (nextText == null) {
      skippedExisting += 1;
      continue;
    }
    if (!dryRun) await fs.writeFile(overview.path, nextText, 'utf8');
    const did = candidateDoubanId(best.raw);
    if (did) seenDoubanIds.add(did);
    associated += 1;
  }

  if (!dryRun && (unmatched.length || misassociated.length)) {
    await fs.mkdir(path.dirname(reviewPath), { recursive: true });
    await fs.writeFile(reviewPath, `${JSON.stringify({
      version: 1,
      generated_at: new Date().toISOString(),
      misassociated,
      unmatched,
    }, null, 2)}\n`, 'utf8');
  }

  if (dryRun) console.log('[dry-run] no files written.');
  console.log(`${associated} associated, ${skippedExisting} already had localisations.zh (use --force to replace).`);
  if (skippedMisassoc) console.log(`${skippedMisassoc} candidates skipped (mis-associated — 原作名 names a different vault book).`);
  if (skippedNone) console.log(`${skippedNone} found entries had no usable candidate.`);
  if (skippedUnmatched) console.log(`${skippedUnmatched} cache entries could not be matched to a book overview.`);
}

// Load an import-free TypeScript module by transpiling it to an inline data
// URL. Works only for modules with no runtime imports (cn-matcher.ts has none;
// cn-localise.ts uses a type-only yaml import that is erased by transpilation).
async function loadTsModule(relPath) {
  const absPath = path.join(READER_ROOT, relPath);
  const ts = await import('typescript');
  const source = await fs.readFile(absPath, 'utf8');
  const output = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ES2022,
      target: ts.ScriptTarget.ES2022,
      verbatimModuleSyntax: false,
    },
  }).outputText;
  const url = `data:text/javascript;base64,${Buffer.from(output).toString('base64')}`;
  return import(url);
}

async function exists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

// Only `status: "found"` entries are real associations. A `status: "none"`
// entry means the agent decided this book has NO Chinese translation — its
// cndouban_ids merely hold candidates that surfaced during the author search
// (usually the author's *other*, translated books) and must not be written.
function isFound(entry) {
  return isRecord(entry) && entry.status === 'found';
}

function cacheWorkItems(cache) {
  const out = [];
  if (isRecord(cache?.by_isbn)) {
    for (const [key, entry] of Object.entries(cache.by_isbn)) {
      if (isFound(entry)) out.push({ key: `isbn:${key}`, isbn: normaliseIsbn(key), entry });
    }
  }
  if (isRecord(cache?.by_slug)) {
    for (const [slug, entry] of Object.entries(cache.by_slug)) {
      if (isFound(entry)) out.push({ key: `slug:${slug}`, slug, entry });
    }
  }
  return out;
}

async function loadBookOverviews() {
  const files = await enumerateOverviewFiles(booksRoot);
  const byIsbn = new Map();
  const bySlug = new Map();
  const byRelPath = new Map();
  const all = [];

  for (const file of files) {
    const text = await fs.readFile(file, 'utf8');
    const parsed = parseMarkdown(text);
    if (!parsed.fm) continue;
    const relPath = toRepoPath(file);
    const slug = slugForOverview(file);
    const overview = {
      path: file,
      relPath,
      slug,
      text,
      fm: parsed.fm,
      isbn13: normaliseIsbn(parsed.fm.isbn),
    };
    all.push(overview);
    byRelPath.set(relPath, overview);
    // A book can carry a stray nested duplicate (e.g. a re-processing artifact
    // at <slug>/<sub>/00-overview.md) that maps to the same slug. Files are
    // enumerated sorted, so the canonical top-level overview is seen first;
    // first-wins keeps slug/ISBN resolution pointing at the file the reader
    // actually reads (vault/books/<slug>/00-overview.md).
    if (slug && !bySlug.has(slug)) bySlug.set(slug, overview);
    if (overview.isbn13 && !byIsbn.has(overview.isbn13)) byIsbn.set(overview.isbn13, overview);
  }

  return { all, byIsbn, bySlug, byRelPath };
}

async function enumerateOverviewFiles(dir) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...await enumerateOverviewFiles(fullPath));
    } else if (entry.isFile() && entry.name === '00-overview.md') {
      files.push(fullPath);
    }
  }
  return files.sort();
}

function resolveOverview(item, overviews) {
  if (item.isbn && overviews.byIsbn.has(item.isbn)) return overviews.byIsbn.get(item.isbn);
  for (const candidatePath of pathHints(item.entry)) {
    const overview = overviews.byRelPath.get(candidatePath);
    if (overview) return overview;
  }
  for (const slug of slugHints(item)) {
    const overview = overviews.bySlug.get(slug);
    if (overview) return overview;
  }
  for (const isbn of isbnHints(item.entry)) {
    const overview = overviews.byIsbn.get(isbn);
    if (overview) return overview;
  }
  return null;
}

function pathHints(entry) {
  const hints = [];
  if (typeof entry.path === 'string') hints.push(entry.path);
  if (typeof entry.book_path === 'string') hints.push(entry.book_path);
  for (const book of asArray(entry.books)) {
    if (isRecord(book) && typeof book.path === 'string') hints.push(book.path);
  }
  return hints.map(normaliseRepoPath);
}

function slugHints(item) {
  const hints = [];
  if (item.slug) hints.push(item.slug);
  if (typeof item.entry.slug === 'string') hints.push(item.entry.slug);
  for (const book of asArray(item.entry.books)) {
    if (isRecord(book) && typeof book.slug === 'string') hints.push(book.slug);
  }
  if (!item.isbn && !item.key.startsWith('isbn:')) hints.push(item.key.replace(/^slug:/, ''));
  return hints.filter(Boolean);
}

function isbnHints(entry) {
  const hints = [];
  if (entry.isbn) hints.push(normaliseIsbn(entry.isbn));
  for (const book of asArray(entry.books)) {
    if (isRecord(book)) hints.push(normaliseIsbn(book.isbn));
  }
  return hints.filter(Boolean);
}

function candidateRecords(entry, cache) {
  const direct = asArray(entry.candidates).filter(isRecord);
  if (direct.length) return direct;

  const byDouban = isRecord(cache?.by_douban_id) ? cache.by_douban_id : {};
  const ids = [];
  if (entry.selected_id) ids.push(String(entry.selected_id));
  for (const id of asArray(entry.cndouban_ids)) ids.push(String(id));

  const seen = new Set();
  const out = [];
  for (const id of ids) {
    if (seen.has(id)) continue;
    seen.add(id);
    const record = byDouban[id];
    if (isRecord(record)) out.push(record);
  }
  return out;
}

function matchCandidateFromRecord(raw) {
  return cleanObject({
    original_title: textOrUndefined(raw.original_title),
    title_cn: textOrUndefined(raw.title),
    authors: coercePeople(raw.authors ?? raw.author),
    year: parseYear(raw.year),
    isbn: normaliseIsbn(raw.isbn ?? raw.isbn_13 ?? raw.isbn_10),
  });
}

function originalFromFrontmatter(fm) {
  const title = textOrUndefined(fm.title);
  if (!title) return null;
  return cleanObject({
    title,
    authors: coercePeople(fm.authors ?? fm.author),
    year: parseYear(fm.year),
    isbn13: normaliseIsbn(fm.isbn),
  });
}

// Mirror the established vault convention (the curated illich-* entries):
// title / translator / publisher / year / isbn / original_title / douban_url /
// ratings_count. The douban subject id is already carried by douban_url, and
// the original author lives on the book's own `authors`, so neither is repeated.
function localisationFromRecord(raw, candidate) {
  return cleanObject({
    title: candidate.title_cn,
    translator: textOrUndefined(raw.translator) ?? joinPeople(raw.translators),
    publisher: textOrUndefined(raw.publisher),
    year: candidate.year,
    isbn: candidate.isbn,
    original_title: candidate.original_title,
    douban_url: textOrUndefined(raw.douban_url ?? raw.preview_link),
    ratings_count: parseInteger(raw.ratings_count),
  });
}

const FENCE = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/;

function parseMarkdown(text) {
  const match = text.match(FENCE);
  if (!match) return { fm: null, body: text };
  const parsed = YAML.parse(match[1]);
  const fm = isRecord(parsed) ? parsed : null;
  return { fm, body: match[2] };
}

function normaliseIsbn(raw) {
  if (Array.isArray(raw)) {
    for (const item of raw) {
      const value = normaliseIsbn(item);
      if (value) return value;
    }
    return null;
  }
  if (raw == null) return null;
  const cleaned = String(raw).replace(/[^0-9Xx]/g, '').toUpperCase();
  if (cleaned.length === 13) return cleaned;
  if (cleaned.length === 10) return isbn10To13(cleaned);
  return null;
}

function isbn10To13(isbn10) {
  const stem = `978${isbn10.slice(0, 9)}`;
  let total = 0;
  for (let i = 0; i < stem.length; i += 1) {
    total += (i % 2 === 0 ? 1 : 3) * Number(stem[i]);
  }
  const check = (10 - (total % 10)) % 10;
  return `${stem}${check}`;
}

function coercePeople(value) {
  if (Array.isArray(value)) return value.map(String).map(s => s.trim()).filter(Boolean);
  if (typeof value === 'string' && value.trim()) {
    return value.split(/\s*[/;,]\s*/).map(s => s.trim()).filter(Boolean);
  }
  return [];
}

function joinPeople(value) {
  const people = coercePeople(value);
  return people.length ? people.join(' / ') : undefined;
}

function parseYear(value) {
  if (Number.isInteger(value)) return value;
  const match = String(value ?? '').match(/\b(1[5-9]\d{2}|20\d{2})\b/);
  return match ? Number(match[1]) : undefined;
}

function parseInteger(value) {
  if (Number.isInteger(value)) return value;
  const parsed = Number.parseInt(String(value ?? ''), 10);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function textOrUndefined(value) {
  if (value == null) return undefined;
  const text = String(value).trim();
  return text ? text : undefined;
}

function cleanObject(object) {
  return Object.fromEntries(
    Object.entries(object).filter(([, value]) => {
      if (value == null) return false;
      if (Array.isArray(value) && value.length === 0) return false;
      if (value === '') return false;
      return true;
    }),
  );
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function hasCjk(value) {
  return /[一-鿿㐀-䶿]/.test(String(value ?? ''));
}

function doubanIdFromUrl(value) {
  const m = String(value ?? '').match(/subject\/(\d+)/);
  return m ? m[1] : null;
}

function candidateDoubanId(raw) {
  const id = raw.douban_id ?? doubanIdFromUrl(raw.douban_url ?? raw.preview_link);
  return id ? String(id) : null;
}

function zhDoubanIds(fm) {
  const zh = isRecord(fm?.localisations) ? fm.localisations.zh : null;
  const items = Array.isArray(zh) ? zh : [];
  return items
    .map(item => (isRecord(item) ? doubanIdFromUrl(item.douban_url) : null))
    .filter(Boolean);
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function toRepoPath(filePath) {
  return normaliseRepoPath(path.relative(repoRoot, filePath));
}

function normaliseRepoPath(value) {
  return value.split(path.sep).join('/');
}

function slugForOverview(filePath) {
  const parts = toRepoPath(filePath).split('/');
  const booksIndex = parts.indexOf('books');
  return booksIndex >= 0 ? parts[booksIndex + 1] : path.basename(path.dirname(filePath));
}

const invokedAsCli = process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedAsCli) {
  if (process.argv.includes('--help') || process.argv.includes('-h')) {
    console.log('Usage: node scripts/write-cn-localisations.mjs [--force]');
    process.exit(0);
  }
  main().catch(error => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
}
