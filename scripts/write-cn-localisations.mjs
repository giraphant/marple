#!/usr/bin/env node
import { promises as fs } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import * as YAML from 'yaml';

const repoRoot = path.resolve(fileURLToPath(new URL('../..', import.meta.url)));
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

  const [{ scoreCandidate, routeByConfidence }, { applyZhLocalisation }] = await Promise.all([
    loadTsModule('reader/src/cn-matcher.ts'),
    loadTsModule('reader/src/cn-localise.ts'),
  ]);
  const cache = await readJson(cachePath);
  const overviews = await loadBookOverviews();
  const workItems = cacheWorkItems(cache);
  const reviewQueue = [];
  const unmatched = [];

  let highAssociated = 0;
  let reviewQueued = 0;
  let skippedNone = 0;
  let skippedExisting = 0;
  let skippedUnmatched = 0;

  for (const item of workItems) {
    const overview = resolveOverview(item, overviews);
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

    const candidates = candidateRecords(item.entry, cache);
    if (!candidates.length) {
      skippedNone += 1;
      continue;
    }

    const scored = candidates
      .map(raw => {
        const candidate = matchCandidateFromRecord(raw);
        const result = scoreCandidate(candidate, original);
        return { raw, candidate, result };
      })
      .sort((a, b) => b.result.score - a.result.score);

    const high = scored.find(item => routeByConfidence(item.result.confidence) === 'write');
    if (high) {
      const localisation = localisationFromRecord(high.raw, high.candidate);
      const nextText = applyZhLocalisation(YAML, overview.text, localisation, { force });
      if (nextText == null) {
        skippedExisting += 1;
        continue;
      }
      if (!dryRun) await fs.writeFile(overview.path, nextText, 'utf8');
      highAssociated += 1;
      continue;
    }

    // The cache already holds candidates found by searching for *this* book, so
    // a borderline match is more likely the right translation than noise. Surface
    // both medium and low for human confirmation rather than dropping them —
    // silent drops are the reason "很多关联不上". Only no-signal (none) is skipped.
    for (const row of scored) {
      if (routeByConfidence(row.result.confidence) === 'review') {
        reviewQueued += 1;
        reviewQueue.push({
          book: {
            slug: overview.slug,
            path: overview.relPath,
            title: original.title,
            authors: original.authors ?? [],
            year: original.year ?? null,
            isbn13: original.isbn13 ?? null,
          },
          candidate: localisationFromRecord(row.raw, row.candidate),
          match: row.result,
        });
      } else {
        skippedNone += 1;
      }
    }
  }

  if (!dryRun && (reviewQueue.length || unmatched.length)) {
    reviewQueue.sort((a, b) => b.match.score - a.match.score);
    await fs.mkdir(path.dirname(reviewPath), { recursive: true });
    await fs.writeFile(reviewPath, `${JSON.stringify({
      version: 1,
      generated_at: new Date().toISOString(),
      review: reviewQueue,
      unmatched,
    }, null, 2)}\n`, 'utf8');
  }

  if (dryRun) console.log('[dry-run] no files written.');
  console.log(`${highAssociated} high auto-associated, ${reviewQueued} queued for review (medium/low), ${skippedNone} skipped (none).`);
  if (skippedExisting) console.log(`${skippedExisting} high-confidence matches skipped because localisations.zh already exists; pass --force to replace zh[0].`);
  if (skippedUnmatched) console.log(`${skippedUnmatched} cache entries could not be matched to a book overview.`);
}

// Load an import-free TypeScript module by transpiling it to an inline data
// URL. Works only for modules with no runtime imports (cn-matcher.ts has none;
// cn-localise.ts uses a type-only yaml import that is erased by transpilation).
async function loadTsModule(relPath) {
  const absPath = path.join(repoRoot, relPath);
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

function cacheWorkItems(cache) {
  const out = [];
  if (isRecord(cache?.by_isbn)) {
    for (const [key, entry] of Object.entries(cache.by_isbn)) {
      if (isRecord(entry)) out.push({ key: `isbn:${key}`, isbn: normaliseIsbn(key), entry });
    }
  }
  if (isRecord(cache?.by_slug)) {
    for (const [slug, entry] of Object.entries(cache.by_slug)) {
      if (isRecord(entry)) out.push({ key: `slug:${slug}`, slug, entry });
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
    console.log('Usage: node reader/scripts/write-cn-localisations.mjs [--force]');
    process.exit(0);
  }
  main().catch(error => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
}
