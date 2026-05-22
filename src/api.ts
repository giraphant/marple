import type { Entry } from './types';
import type { EmbedStatus } from './embedding';
import type { SearchMode } from './searchMode';
import { parseFile, serializeFile } from './frontmatter';

export type { SearchMode };

const NOTES_DIR = 'vault/notes/';

// ---- Trash API client ----------------------------------------------------

export interface TrashItem {
  name: string;            // <base>.<iso-ts>.md  (filename in .trash/)
  originalBase: string | null;
  ts: string | null;       // ISO ts with `:` and `.` replaced by `-`
  mtime: number;
  size: number;
}

export async function listTrash(): Promise<TrashItem[]> {
  const r = await fetch('/api/trash');
  if (!r.ok) throw new Error(`list trash failed: ${r.status}`);
  const json = await r.json() as { items: TrashItem[] };
  return json.items ?? [];
}

export async function restoreTrash(name: string): Promise<string> {
  const r = await fetch(`/api/trash/${encodeURIComponent(name)}/restore`, { method: 'POST' });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`restore failed: ${r.status} ${msg}`);
  }
  const json = await r.json().catch(() => ({} as { restored?: string }));
  return json.restored ?? '';
}

/** Fetch the reader index (DB metadata cache snapshot) on boot. */
export async function fetchIndex(): Promise<Entry[]> {
  const r = await fetch('/api/index');
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`fetch index failed: ${r.status} ${msg}`);
  }
  const json = await r.json().catch(() => ({} as { items?: Entry[] }));
  return json.items ?? [];
}

export interface VaultFile {
  path: string;
  mtime: number | null;
}

export interface VaultFilesResult {
  items: VaultFile[];
  total: number;
}

/** Cheap directory listing — the file-browser's "what exists". With `since`
 *  (epoch ms) only changed files come back (the delta); `total` is always the
 *  full count so the caller can detect deletions. */
export async function listFiles(since?: number): Promise<VaultFilesResult> {
  const url = since != null ? `/api/files?since=${since}` : '/api/files';
  const r = await fetch(url);
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`list files failed: ${r.status} ${msg}`);
  }
  const json = await r.json().catch(() => ({} as { items?: VaultFile[]; total?: number }));
  const items = json.items ?? [];
  return { items, total: json.total ?? items.length };
}

/** Live-parse one vault file's metadata straight from disk (no DB). Returns
 *  null when the file is missing or has no usable type (not a renderable entry). */
export async function fetchEntry(path: string): Promise<Entry | null> {
  const r = await fetch('/api/entry?path=' + encodeURIComponent(path));
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`fetch entry failed: ${r.status} ${msg}`);
  }
  const json = await r.json().catch(() => ({} as { entry?: Entry | null }));
  return json.entry ?? null;
}

export interface SearchHit {
  entry: Entry;
  score: number;
  snippet?: string | null;
  source: string;
}

export interface SearchParams {
  q: string;
  type?: Entry['type'];
  minRating?: number;
  theme?: string | null;
  limit?: number;
  mode?: SearchMode;
  signal?: AbortSignal;
}

/** Server-side full-text search backed by SQLite FTS/trigram indexes. */
export async function searchIndex({
  q, type, minRating, theme, limit, mode, signal,
}: SearchParams): Promise<SearchHit[]> {
  const params = new URLSearchParams();
  params.set('q', q);
  if (type) params.set('type', type);
  if (minRating) params.set('minRating', String(minRating));
  if (theme) params.set('theme', theme);
  if (limit) params.set('limit', String(limit));
  if (mode) params.set('mode', mode);
  const r = await fetch(`/api/search?${params.toString()}`, { signal });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`search failed: ${r.status} ${msg}`);
  }
  const json = await r.json().catch(() => ({} as { items?: SearchHit[] }));
  return json.items ?? [];
}

/** A vault file the indexer left out, with why (no `type` field, or a `type`
 *  value that maps to no known entry kind). Surfaced after a reindex so a
 *  dropped entry is never silent. */
export interface SkippedFile {
  path: string;
  reason: string;
}

/** Trigger a full rebuild of data/index.sqlite on the server. Resolves once
 *  the new index database is written; caller should re-fetch /api/index
 *  afterwards. `skipped` lists files that had frontmatter but were left out. */
export async function reindex(): Promise<{ tookMs: number; skipped: SkippedFile[] }> {
  const r = await fetch('/api/reindex', { method: 'POST' });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`reindex failed: ${r.status} ${msg}`);
  }
  const json = await r.json().catch(() => ({} as { tookMs?: number; skipped?: SkippedFile[] }));
  return { tookMs: json.tookMs ?? 0, skipped: json.skipped ?? [] };
}

/** Cheap delta-sync: ask the server to bring the index into agreement with the
 *  vault by diffing per-file mtimes (new/changed/deleted), instead of a full
 *  rebuild. Called on window focus so quick search reflects external edits made
 *  while away. */
export async function reconcile(): Promise<{ upserted: number; removed: number; unchanged: number }> {
  const r = await fetch('/api/reconcile', { method: 'POST' });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`reconcile failed: ${r.status} ${msg}`);
  }
  const json = await r.json().catch(() => ({} as { upserted?: number; removed?: number; unchanged?: number }));
  return { upserted: json.upserted ?? 0, removed: json.removed ?? 0, unchanged: json.unchanged ?? 0 };
}

/** Advanced/opt-in: start a background semantic-vector build. Returns
 *  immediately — the heavy model load + embed runs server-side as a detached
 *  job; poll {@link embeddingStatus}. `started` is false when a build was
 *  already running (HTTP 409); the caller just keeps polling. */
export async function triggerEmbeddings(): Promise<{ started: boolean; status: EmbedStatus }> {
  const r = await fetch('/api/embeddings', { method: 'POST' });
  if (r.status === 202 || r.status === 409) {
    const status = await r.json() as EmbedStatus;
    return { started: r.status === 202, status };
  }
  const msg = await r.text().catch(() => '');
  throw new Error(`trigger embeddings failed: ${r.status} ${msg}`);
}

/** Poll the embedding job state + the truthful on-disk vectors summary. */
export async function embeddingStatus(): Promise<EmbedStatus> {
  const r = await fetch('/api/embeddings/status');
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`embedding status failed: ${r.status} ${msg}`);
  }
  return await r.json() as EmbedStatus;
}

/** Ask the backend to open sources/<slug>.pdf in the host's default PDF app
 *  (QUA-55). The browser can't launch native apps, so reader-api does it. */
export async function openPdfExternal(slug: string): Promise<void> {
  const r = await fetch('/api/open-pdf', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ slug }),
  });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`open pdf failed: ${r.status} ${msg}`);
  }
}

/** Ask the backend to open a vault markdown file in the chosen external editor
 *  (QUA-72). `app` is the editor app name (macOS `open -a`) / binary (Linux);
 *  empty string opens with the OS default `.md` handler. The browser can't launch
 *  native apps, so reader-api does it (no shell — no injection from `app`). */
export async function openInEditor(path: string, app: string): Promise<void> {
  // Bound the request: launching is fire-and-forget on the server (it returns as
  // soon as the launcher is spawned), so a fetch that hasn't resolved in a few
  // seconds is stuck in the browser connection queue, not doing useful work.
  // Aborting frees the connection and lets the caller surface a transient error
  // instead of hanging the "opening…" affordance forever.
  const r = await fetch('/api/open-in-editor', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path, app }),
    signal: AbortSignal.timeout(8000),
  });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`open in editor failed: ${r.status} ${msg}`);
  }
}

/** Slugs that have a translated PDF under processing/translations/<slug>-zh.pdf.
 *  Fetched once on boot; used to decide whether to show the 「打开译本」 button.
 *  Read live by the backend, so it reflects newly-added translations on reload. */
export async function fetchTranslationSlugs(): Promise<string[]> {
  try {
    const r = await fetch('/api/translations');
    if (!r.ok) return [];
    return await r.json() as string[];
  } catch {
    return [];
  }
}

/** Ask the backend to open processing/translations/<slug>-zh.pdf in the host's
 *  default PDF app (mirrors openPdfExternal). */
export async function openTranslationExternal(slug: string): Promise<void> {
  const r = await fetch('/api/open-translation', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ slug }),
  });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`open translation failed: ${r.status} ${msg}`);
  }
}

export async function purgeTrash(name: string): Promise<void> {
  const r = await fetch(`/api/trash/${encodeURIComponent(name)}`, { method: 'DELETE' });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`purge failed: ${r.status} ${msg}`);
  }
}

/** Reverse the trash filename to its (likely) vault path on successful restore. */
export function trashRestoredPath(name: string): string {
  // Trash format: <base>.<isoTs>.md
  const m = name.match(/\.(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z)\.md$/);
  if (!m) return `vault/notes/${name}`;
  return `vault/notes/${name.slice(0, m.index)}.md`;
}

/** Fetch a vault md file as text. */
export async function fetchEntryText(path: string): Promise<string> {
  const r = await fetch('/' + path);
  if (!r.ok) throw new Error(`fetch ${path} failed: ${r.status}`);
  return r.text();
}

/** Write a vault md file back via PUT /vault/...md. Returns the new body text. */
export async function putEntryText(path: string, text: string): Promise<void> {
  const r = await fetch('/' + path, {
    method: 'PUT',
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
    body: text,
  });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`PUT ${path} failed: ${r.status} ${msg}`);
  }
}

/**
 * Read the file, apply `mutate` to the parsed frontmatter, re-serialize and
 * PUT it back. Returns the new fm so callers can refresh their local index.
 */
export async function patchFrontmatter(
  path: string,
  mutate: (fm: Record<string, unknown>) => Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const text = await fetchEntryText(path);
  const { fm, body } = parseFile(text);
  const next = mutate(fm ?? {});
  const out = serializeFile(next, body);
  await putEntryText(path, out);
  return next;
}

/** Soft-delete a note via DELETE. Server moves it into vault/notes/.trash/ with
 *  a timestamped basename so successive deletions of same-name files don't
 *  collide. Returns the trash path written by the server. */
export async function deleteEntry(path: string): Promise<string> {
  const r = await fetch('/' + path, { method: 'DELETE' });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`DELETE ${path} failed: ${r.status} ${msg}`);
  }
  const json = await r.json().catch(() => ({} as { trash?: string }));
  return json.trash ?? '';
}

/**
 * Re-assemble the file from an existing raw markdown text and a new body
 * string, preserving the frontmatter fence and content exactly. Used by the
 * auto-saving body editor.
 */
export function replaceBody(rawText: string, newBody: string): string {
  const m = rawText.match(/^(---\r?\n[\s\S]*?\r?\n---\r?\n?)([\s\S]*)$/);
  if (!m) {
    // No frontmatter — file is rare in this vault but we still allow editing.
    return newBody;
  }
  // Capture group 1 already includes the newline after the closing fence;
  // newBody is what came out of parseFile, so any leading blank line in it is
  // the user's original spacing. Concatenate as-is — stripping would lose it.
  return m[1] + newBody;
}

/** Create a new note file via POST. The path must live under vault/notes/. */
export async function postEntryText(path: string, text: string): Promise<void> {
  if (!path.startsWith(NOTES_DIR)) {
    throw new Error(`POST only allowed under ${NOTES_DIR}, got ${path}`);
  }
  const r = await fetch('/' + path, {
    method: 'POST',
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
    body: text,
  });
  if (!r.ok) {
    const msg = await r.text().catch(() => '');
    throw new Error(`POST ${path} failed: ${r.status} ${msg}`);
  }
}

/** Slugify a title-ish string for a filename. ASCII letters/digits/dashes only. */
function slugify(s: string): string {
  return s.toLowerCase()
    .replace(/[^\w\-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 60) || 'note';
}

/** Build the {path, body} for a new annotation note targeting `target`. */
export function newAnnotationDraft(target: Entry): { path: string; body: string; title: string } {
  const targetSlug = target.path.split('/').pop()!.replace(/\.md$/, '');
  const baseSlug = slugify(targetSlug);
  const stamp = Date.now().toString(36).slice(-4);
  const path = `${NOTES_DIR}${baseSlug}-note-${stamp}.md`;
  const today = new Date().toISOString().slice(0, 10);
  const title = `对《${target.title || targetSlug}》的批注`;
  const body =
    `---\n` +
    `type: note\n` +
    `title: ${JSON.stringify(title)}\n` +
    `annotates: ${target.path}\n` +
    `created: ${today}\n` +
    `themes: []\n` +
    `---\n\n` +
    `# ${title}\n\n`;
  return { path, body, title };
}

/** Build the {path, body} for a fresh standalone idea note (no `annotates`). */
export function newIdeaDraft(): { path: string; body: string; title: string } {
  const today = new Date().toISOString().slice(0, 10);
  const stamp = Date.now().toString(36).slice(-4);
  const path = `${NOTES_DIR}${today}-idea-${stamp}.md`;
  const title = `${today} — 新笔记`;
  const body =
    `---\n` +
    `type: note\n` +
    `title: ${JSON.stringify(title)}\n` +
    `created: ${today}\n` +
    `themes: []\n` +
    `---\n\n` +
    `# ${title}\n\n`;
  return { path, body, title };
}

/** Build an Entry row for a freshly-posted standalone idea note. */
export function ideaEntryFromDraft(path: string, title: string): Entry {
  const today = new Date().toISOString().slice(0, 10);
  return {
    path,
    type: 'note',
    book: null,
    title,
    author: null,
    year: null,
    rating: null,
    rating_score: 0,
    themes: [],
    topic: null,
    source: null,
    doi: null,
    chapters_analyzed: null,
    annotates: null,
    created: today,
    preview: '',
  };
}

/** Build an Entry row matching the freshly-posted note, so the UI can show it without re-indexing. */
export function entryFromDraft(path: string, target: Entry, title: string): Entry {
  const today = new Date().toISOString().slice(0, 10);
  return {
    path,
    type: 'note',
    book: null,
    title,
    author: null,
    year: null,
    rating: null,
    rating_score: 0,
    themes: [],
    topic: null,
    source: null,
    doi: null,
    chapters_analyzed: null,
    annotates: target.path,
    created: today,
    preview: '',
  };
}

/** Merge frontmatter changes back into the in-memory Entry row. */
export function applyFmToEntry(entry: Entry, fm: Record<string, unknown>): Entry {
  const next: Entry = { ...entry };
  if ('rating' in fm) next.rating = fm.rating as Entry['rating'];
  if ('year' in fm) next.year = fm.year as Entry['year'];
  if ('author' in fm) next.author = flattenAuthor(fm.author);
  if ('title' in fm) next.title = fm.title as Entry['title'];
  if ('title_en' in fm) next.title_en = textCell(fm.title_en);
  if ('chapter_title_en' in fm && !('title_en' in fm)) next.title_en = textCell(fm.chapter_title_en);
  if ('title_cn' in fm) next.title_cn = textCell(fm.title_cn);
  if ('title_zh' in fm && !('title_cn' in fm)) next.title_cn = textCell(fm.title_zh);
  if ('chapter_title_cn' in fm && !('title_cn' in fm)) next.title_cn = textCell(fm.chapter_title_cn);
  if ('chapter_title_zh' in fm && !('title_cn' in fm) && !('chapter_title_cn' in fm)) next.title_cn = textCell(fm.chapter_title_zh);
  if ('source' in fm) next.source = fm.source as Entry['source'];
  if ('topic' in fm) next.topic = fm.topic as Entry['topic'];
  if ('doi' in fm) next.doi = fm.doi as Entry['doi'];
  if ('publisher' in fm) next.publisher = textCell(fm.publisher);
  if ('isbn' in fm) next.isbn = textCell(fm.isbn);
  if ('localisations' in fm) {
    const zh = firstZhLocalisation(fm.localisations);
    next.translation_title_cn = textCell(zh?.title);
    next.translation_douban_url = doubanUrlCell(zh?.douban_url);
  }
  if ('douban_url' in fm && !next.translation_douban_url) next.translation_douban_url = doubanUrlCell(fm.douban_url);
  if ('cndouban' in fm && !next.translation_douban_url) next.translation_douban_url = doubanUrlCell(fm.cndouban);
  if ('themes' in fm) next.themes = Array.isArray(fm.themes) ? fm.themes as string[] : null;
  if ('annotates' in fm) next.annotates = (fm.annotates as string | null) ?? null;
  if ('created' in fm) next.created = fm.created != null ? String(fm.created) : null;
  // Recompute rating_score from the new rating value.
  next.rating_score = scoreRating(next.rating);
  return next;
}

function scoreRating(r: unknown): number {
  if (typeof r === 'number') return r;
  if (typeof r === 'string') {
    const stars = (r.match(/★/g) || []).length;
    if (stars) return stars;
    const n = parseInt(r, 10);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

function flattenAuthor(v: unknown): string | null {
  if (v == null) return null;
  if (Array.isArray(v)) return v.map(String).filter(Boolean).join(', ');
  return typeof v === 'string' ? v : String(v);
}

function textCell(v: unknown): string | null {
  if (v == null) return null;
  const text = String(v).trim();
  return text === '' ? null : text;
}

function firstZhLocalisation(v: unknown): Record<string, unknown> | null {
  if (!v || typeof v !== 'object') return null;
  const zh = (v as Record<string, unknown>).zh;
  const first = Array.isArray(zh) ? zh[0] : zh;
  return first && typeof first === 'object' ? first as Record<string, unknown> : null;
}

function doubanUrlCell(v: unknown): string | null {
  if (Array.isArray(v)) return v.map(doubanUrlCell).find(Boolean) ?? null;
  const text = textCell(v);
  if (!text) return null;
  if (text.startsWith('http://') || text.startsWith('https://')) return text;
  const id = text.replace(/\D/g, '');
  return id ? `https://book.douban.com/subject/${id}/` : null;
}
