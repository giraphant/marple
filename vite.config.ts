import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';
import Icons from 'unplugin-icons/vite';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Vite dev runs on 5173 by default; the Rust reader-api runs on 5174 and is the
// source of truth for /api/*, /vault/* and /sources/* fetches.
// In dev, we proxy those paths through to reader-api so the SPA
// can keep using absolute paths in production too.
//
// Both ports are overridable via env vars (e.g. when 5173/5174 collide with
// another dev session). PORT here is the same one reader-api reads, so a single
// var controls both the backend's listen address AND the proxy target:
//   VITE_PORT=6173 PORT=6174 npm run dev
const FRONTEND_PORT = Number(process.env.VITE_PORT || 5173);
const BACKEND_PORT = Number(process.env.PORT || 5174);
const BACKEND = `http://localhost:${BACKEND_PORT}`;

export default defineConfig({
  plugins: [
    preact(),
    // ~icons/<set>/<name> imports — compiles each SVG into a Preact component
    // at build time, so only icons actually imported make it into the bundle.
    // We only need Phosphor; add @iconify-json/<other> deps to enable more sets.
    Icons({ compiler: 'jsx', jsx: 'preact' }),
  ],
  root: __dirname,
  base: '/reader/',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: true,
  },
  server: {
    port: FRONTEND_PORT,
    proxy: {
      '/vault':       BACKEND,
      '/reader/data': BACKEND,
      '/api':         BACKEND,
      '/sources':     BACKEND,
    },
  },
});
