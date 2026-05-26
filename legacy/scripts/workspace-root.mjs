import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Mirror of reader-core's resolve_workspace_root (rust/reader-core/src/lib.rs):
// the marple repo only points at where the content lives; it never assumes it
// sits beside the vault.
//   1. VAULT_ROOT env var (explicit override for CI/scripts/dev)
//   2. marple.config.json's workspaceRoot (relative paths resolve against the
//      marple repo root)

const READER_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

export function readerRoot() {
  return READER_ROOT;
}

export function workspaceRoot() {
  const env = process.env.VAULT_ROOT;
  if (env) return path.resolve(env);
  const cfg = path.join(READER_ROOT, 'marple.config.json');
  if (existsSync(cfg)) {
    const ws = JSON.parse(readFileSync(cfg, 'utf8')).workspaceRoot;
    if (ws) return path.isAbsolute(ws) ? ws : path.resolve(READER_ROOT, ws);
  }
  throw new Error(
    `no vault configured: set VAULT_ROOT or add {"workspaceRoot": "…"} to ${cfg}`,
  );
}

// Per-vault derived data (index, vectors, generated reports) lives next to the
// vault, not in the marple repo.
export function marpleDataDir() {
  return path.join(workspaceRoot(), '.marple');
}
