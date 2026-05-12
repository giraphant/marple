#!/usr/bin/env node
// Tiny static file server rooted at the worktree, so the reader can fetch
// both reader/data/index.json and vault/**/*.md with absolute paths.
//
// Usage: node reader/serve.mjs   (or `PORT=5174 node reader/serve.mjs`)

import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const PORT = Number(process.env.PORT || 5174);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.ico': 'image/x-icon',
};

const server = http.createServer(async (req, res) => {
  try {
    let url = decodeURIComponent(req.url.split('?')[0]);
    if (url === '/') url = '/reader/index.html';
    if (url.endsWith('/')) url += 'index.html';
    const fp = path.resolve(path.join(ROOT, url));
    if (!fp.startsWith(ROOT + path.sep) && fp !== ROOT) {
      res.writeHead(403); res.end('forbidden'); return;
    }
    const s = await stat(fp).catch(() => null);
    if (!s || !s.isFile()) {
      res.writeHead(404); res.end('not found'); return;
    }
    const buf = await readFile(fp);
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(fp).toLowerCase()] || 'application/octet-stream',
      'Cache-Control': 'no-cache',
    });
    res.end(buf);
  } catch (e) {
    res.writeHead(500); res.end(String(e));
  }
});

server.listen(PORT, () => {
  console.log(`reader at http://localhost:${PORT}/reader/`);
});
