import { saveDecision } from './live';

export type SaveStatus = 'saving' | 'saved' | 'conflict' | 'error';

export interface SaveQueueDeps {
  /** Read the current on-disk text for a path. */
  fetchText: (path: string) => Promise<string>;
  /** Write text for a path. */
  putText: (path: string, text: string) => Promise<void>;
  /** Re-assemble a file from a known-good raw + a new body. */
  replaceBody: (baseRaw: string, body: string) => string;
  /** Report per-path save status (the UI filters by which path is visible). */
  onStatus?: (path: string, status: SaveStatus, err?: string) => void;
  /** Called after a successful write with the new raw (e.g. to signal windows). */
  onSaved?: (path: string, rawOut: string) => void;
}

export interface SaveQueue {
  /** Record the last raw we loaded/wrote for a path (conflict base). */
  seedBase(path: string, raw: string): void;
  /** Queue the latest body for a path and ensure it gets written. */
  request(path: string, body: string): void;
  /** Discard a path's queued edit (e.g. user reloaded from disk). */
  drop(path: string): void;
}

/**
 * Serializes saves per path so concurrent autosaves and navigating away can't
 * drop edits. Each path drains one PUT at a time, latest-body-wins; a save in
 * flight picks up any edit queued during it. The drain runs independently of
 * any UI component, so edits queued just before a tab/doc switch are still
 * written to the correct file. Never overwrites a file that changed underneath
 * (optimistic-concurrency via `saveDecision`).
 */
export function createSaveQueue(deps: SaveQueueDeps): SaveQueue {
  const pending = new Map<string, string>();
  const inFlight = new Set<string>();
  const lastBase = new Map<string, string>();

  async function drain(path: string): Promise<void> {
    if (inFlight.has(path)) return;
    inFlight.add(path);
    try {
      while (pending.has(path)) {
        const body = pending.get(path)!;
        pending.delete(path);
        deps.onStatus?.(path, 'saving');
        const base = lastBase.get(path) ?? '';
        let disk: string | null;
        try { disk = await deps.fetchText(path); } catch { disk = null; }
        if (saveDecision(base, disk) === 'conflict') {
          deps.onStatus?.(path, 'conflict');
          return;
        }
        const out = deps.replaceBody(base, body);
        try {
          await deps.putText(path, out);
        } catch (e) {
          // Keep the edit queued so a later request retries it.
          pending.set(path, body);
          deps.onStatus?.(path, 'error', e instanceof Error ? e.message : String(e));
          return;
        }
        lastBase.set(path, out);
        deps.onSaved?.(path, out);
        if (!pending.has(path)) deps.onStatus?.(path, 'saved');
      }
    } finally {
      inFlight.delete(path);
    }
  }

  return {
    seedBase(path, raw) { lastBase.set(path, raw); },
    request(path, body) { pending.set(path, body); void drain(path); },
    drop(path) { pending.delete(path); },
  };
}
