#!/usr/bin/env node
// Tiny static file server rooted at the worktree, plus a PUT /vault/*.md
// endpoint for write-back from the reader UI.
//
// Usage: node reader/serve.mjs   (or `PORT=5174 node reader/serve.mjs`)

import http from 'node:http';
import { readFile, stat, writeFile, rename, mkdir, readdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const VAULT = path.join(ROOT, 'vault');
const NOTES_DIR = path.join(VAULT, 'notes');
const TRASH_DIR = path.join(NOTES_DIR, '.trash');
const PORT = Number(process.env.PORT || 5174);
const MAX_PUT_BYTES = 5 * 1024 * 1024; // 5 MB safety cap

// Trash filename format: <base>.<ISO-ts>.md, where ISO-ts has `:` and `.`
// replaced with `-` (set by handleDelete). This regex recovers `<base>`.
const TRASH_TS_RE = /\.(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z)\.md$/;

function trashOriginalBase(trashName) {
  const m = trashName.match(TRASH_TS_RE);
  if (!m) return null;
  return trashName.slice(0, m.index);
}

function trashTs(trashName) {
  const m = trashName.match(TRASH_TS_RE);
  return m ? m[1] : null;
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.mjs':  'text/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.md':   'text/markdown; charset=utf-8',
  '.pdf':  'application/pdf',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.ico':  'image/x-icon',
};

function send(res, status, body, headers = {}) {
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, PUT, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    ...headers,
  });
  res.end(body);
}

function resolveSafe(urlPath) {
  // Decode, drop query string, strip leading slash.
  const url = decodeURIComponent(urlPath.split('?')[0]);
  let normalized = url;
  if (normalized === '/') normalized = '/reader/index.html';
  if (normalized.endsWith('/')) normalized += 'index.html';
  const fp = path.resolve(path.join(ROOT, normalized));
  if (fp !== ROOT && !fp.startsWith(ROOT + path.sep)) return null;
  return fp;
}

async function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', c => {
      size += c.length;
      if (size > MAX_PUT_BYTES) {
        reject(Object.assign(new Error('payload too large'), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function handleGet(req, res) {
  const fp = resolveSafe(req.url);
  if (!fp) return send(res, 403, 'forbidden');
  const s = await stat(fp).catch(() => null);
  if (!s || !s.isFile()) return send(res, 404, 'not found');
  const buf = await readFile(fp);
  res.writeHead(200, {
    'Content-Type': MIME[path.extname(fp).toLowerCase()] || 'application/octet-stream',
    'Cache-Control': 'no-cache',
  });
  res.end(buf);
}

async function handlePut(req, res) {
  const fp = resolveSafe(req.url);
  if (!fp) return send(res, 403, 'forbidden');
  // Only allow PUT into vault/*.md — never into reader/, sources/, drafts/, etc.
  if (!fp.startsWith(VAULT + path.sep)) return send(res, 403, 'PUT only allowed under /vault/');
  if (path.extname(fp).toLowerCase() !== '.md') return send(res, 415, 'only .md files writable');
  // Refuse if the target doesn't already exist — we don't want the UI silently
  // creating arbitrary new files. (Create-new is a separate planned feature.)
  const s = await stat(fp).catch(() => null);
  if (!s || !s.isFile()) return send(res, 404, 'target file does not exist');

  let body;
  try { body = await readBody(req); }
  catch (e) {
    const status = (e && e.status) || 400;
    return send(res, status, e?.message || 'bad request');
  }
  // Sanity: must look like a md file with `---` frontmatter fence, otherwise
  // it's almost certainly a mistake (we don't want to clobber a file with JSON).
  const head = body.slice(0, 4).toString('utf8');
  if (head !== '---\n' && head !== '---\r') {
    return send(res, 400, 'body must start with --- frontmatter fence');
  }

  // Atomic write: temp file in the same dir + rename.
  const dir = path.dirname(fp);
  await mkdir(dir, { recursive: true });
  const tmp = path.join(dir, `.${path.basename(fp)}.${randomBytes(6).toString('hex')}.tmp`);
  await writeFile(tmp, body);
  await rename(tmp, fp);

  const after = await stat(fp);
  send(res, 200, JSON.stringify({ ok: true, bytes: body.length, mtime: after.mtimeMs }), {
    'Content-Type': 'application/json; charset=utf-8',
  });
}

async function handlePost(req, res) {
  const fp = resolveSafe(req.url);
  if (!fp) return send(res, 403, 'forbidden');
  // POST is only allowed for *creating* new note files under vault/notes/.
  if (!fp.startsWith(NOTES_DIR + path.sep)) return send(res, 403, 'POST only allowed under /vault/notes/');
  if (path.extname(fp).toLowerCase() !== '.md') return send(res, 415, 'only .md files creatable');
  const existing = await stat(fp).catch(() => null);
  if (existing) return send(res, 409, 'file already exists; use PUT to update');

  let body;
  try { body = await readBody(req); }
  catch (e) {
    const status = (e && e.status) || 400;
    return send(res, status, e?.message || 'bad request');
  }
  const head = body.slice(0, 4).toString('utf8');
  if (head !== '---\n' && head !== '---\r') {
    return send(res, 400, 'body must start with --- frontmatter fence');
  }

  const dir = path.dirname(fp);
  await mkdir(dir, { recursive: true });
  const tmp = path.join(dir, `.${path.basename(fp)}.${randomBytes(6).toString('hex')}.tmp`);
  await writeFile(tmp, body);
  await rename(tmp, fp);

  const after = await stat(fp);
  send(res, 201, JSON.stringify({ ok: true, bytes: body.length, mtime: after.mtimeMs, path: path.relative(ROOT, fp).split(path.sep).join('/') }), {
    'Content-Type': 'application/json; charset=utf-8',
  });
}

// ---- Trash API (/api/trash) ----------------------------------------------

async function handleTrashList(_req, res) {
  const dir = await stat(TRASH_DIR).catch(() => null);
  if (!dir || !dir.isDirectory()) {
    return send(res, 200, JSON.stringify({ items: [] }), {
      'Content-Type': 'application/json; charset=utf-8',
    });
  }
  const names = await readdir(TRASH_DIR);
  const items = [];
  for (const name of names) {
    if (!name.endsWith('.md')) continue;
    const fp = path.join(TRASH_DIR, name);
    const s = await stat(fp).catch(() => null);
    if (!s || !s.isFile()) continue;
    items.push({
      name,
      originalBase: trashOriginalBase(name),
      ts: trashTs(name),
      mtime: s.mtimeMs,
      size: s.size,
    });
  }
  // Newest first by mtime so the most-recently-trashed sits at the top.
  items.sort((a, b) => b.mtime - a.mtime);
  send(res, 200, JSON.stringify({ items }), {
    'Content-Type': 'application/json; charset=utf-8',
  });
}

function trashTargetPath(name) {
  // Reject anything that escapes the trash directory.
  if (!name || name.includes('/') || name.includes('\\') || name.startsWith('.')) return null;
  if (!name.endsWith('.md')) return null;
  const fp = path.resolve(path.join(TRASH_DIR, name));
  if (fp !== TRASH_DIR && !fp.startsWith(TRASH_DIR + path.sep)) return null;
  return fp;
}

async function handleTrashRestore(req, res, trashName) {
  const fp = trashTargetPath(trashName);
  if (!fp) return send(res, 403, 'invalid trash name');
  const s = await stat(fp).catch(() => null);
  if (!s || !s.isFile()) return send(res, 404, 'trash item not found');
  const base = trashOriginalBase(trashName);
  if (!base) return send(res, 400, 'cannot determine original base name');
  const target = path.join(NOTES_DIR, `${base}.md`);
  const existing = await stat(target).catch(() => null);
  if (existing) return send(res, 409, `restore target already exists: ${base}.md`);
  await rename(fp, target);
  send(res, 200, JSON.stringify({
    ok: true,
    restored: path.relative(ROOT, target).split(path.sep).join('/'),
  }), { 'Content-Type': 'application/json; charset=utf-8' });
}

async function handleTrashPurge(_req, res, trashName) {
  const fp = trashTargetPath(trashName);
  if (!fp) return send(res, 403, 'invalid trash name');
  const s = await stat(fp).catch(() => null);
  if (!s || !s.isFile()) return send(res, 404, 'trash item not found');
  await unlink(fp);
  send(res, 200, JSON.stringify({ ok: true }), {
    'Content-Type': 'application/json; charset=utf-8',
  });
}

async function handleDelete(req, res) {
  const fp = resolveSafe(req.url);
  if (!fp) return send(res, 403, 'forbidden');
  // Scope DELETE to notes only — we don't want the reader UI ever erasing
  // an LLM-generated paper/book/author by accident.
  if (!fp.startsWith(NOTES_DIR + path.sep)) {
    return send(res, 403, 'DELETE only allowed under /vault/notes/');
  }
  if (path.extname(fp).toLowerCase() !== '.md') {
    return send(res, 415, 'only .md files deletable');
  }
  const s = await stat(fp).catch(() => null);
  if (!s || !s.isFile()) return send(res, 404, 'target file does not exist');

  const trashDir = path.join(NOTES_DIR, '.trash');
  await mkdir(trashDir, { recursive: true });
  // Filename-safe ISO timestamp: 2026-05-14T12-34-56-789Z
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const base = path.basename(fp, '.md');
  const trashName = `${base}.${ts}.md`;
  const trashPath = path.join(trashDir, trashName);
  await rename(fp, trashPath);

  send(res, 200, JSON.stringify({
    ok: true,
    trash: path.relative(ROOT, trashPath).split(path.sep).join('/'),
  }), { 'Content-Type': 'application/json; charset=utf-8' });
}

function matchTrashRoute(urlPath) {
  // Returns { kind: 'list' } | { kind: 'restore', name } | { kind: 'purge', name } | null
  const url = decodeURIComponent(urlPath.split('?')[0]);
  if (url === '/api/trash' || url === '/api/trash/') return { kind: 'list' };
  const restoreMatch = url.match(/^\/api\/trash\/([^/]+)\/restore$/);
  if (restoreMatch) return { kind: 'restore', name: restoreMatch[1] };
  const itemMatch = url.match(/^\/api\/trash\/([^/]+)$/);
  if (itemMatch) return { kind: 'item', name: itemMatch[1] };
  return null;
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'OPTIONS') return send(res, 204, '');

    // Trash API takes precedence over the generic file router.
    const trash = matchTrashRoute(req.url);
    if (trash) {
      if (trash.kind === 'list' && (req.method === 'GET' || req.method === 'HEAD')) {
        return handleTrashList(req, res);
      }
      if (trash.kind === 'restore' && req.method === 'POST') {
        return handleTrashRestore(req, res, trash.name);
      }
      if (trash.kind === 'item' && req.method === 'DELETE') {
        return handleTrashPurge(req, res, trash.name);
      }
      return send(res, 405, 'method not allowed for trash route');
    }

    if (req.method === 'GET' || req.method === 'HEAD') return handleGet(req, res);
    if (req.method === 'PUT') return handlePut(req, res);
    if (req.method === 'POST') return handlePost(req, res);
    if (req.method === 'DELETE') return handleDelete(req, res);
    send(res, 405, 'method not allowed');
  } catch (e) {
    console.error('[serve]', e);
    send(res, 500, String(e));
  }
});

server.listen(PORT, () => {
  console.log(`reader at http://localhost:${PORT}/reader/`);
  console.log(`PUT    /vault/**/*.md          → updates existing vault md files`);
  console.log(`POST   /vault/notes/**/*.md    → creates new notes under ${path.relative(process.cwd(), NOTES_DIR) || NOTES_DIR}`);
  console.log(`DELETE /vault/notes/**/*.md    → soft-deletes (moves into vault/notes/.trash/)`);
  console.log(`GET    /api/trash              → list trashed notes`);
  console.log(`POST   /api/trash/<name>/restore → restore by trash filename`);
  console.log(`DELETE /api/trash/<name>       → permanently delete`);
});
