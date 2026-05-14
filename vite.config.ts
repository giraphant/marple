import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';
import Icons from 'unplugin-icons/vite';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Vite dev runs on 5173 (default). The Node serve.mjs runs on 5174 and is the
// source of truth for both reader/data/index.json and vault/**/*.md fetches.
// In dev, we proxy /vault/* and /reader/data/* through to serve.mjs so the SPA
// can keep using absolute paths in production too.
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
    port: 5173,
    proxy: {
      '/vault': 'http://localhost:5174',
      '/reader/data': 'http://localhost:5174',
    },
  },
});
