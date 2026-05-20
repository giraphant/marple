import { describe, it, expect } from 'vitest';
import { createSaveQueue, type SaveQueueDeps } from './save-queue';

const tick = () => new Promise<void>(r => setTimeout(r, 0));

/** A fake disk + recorders. fetchText returns current disk content; putText
 *  writes it. replaceBody concatenates base|body so assertions are legible. */
function harness(initial: Record<string, string> = {}) {
  const disk = new Map<string, string>(Object.entries(initial));
  const puts: Array<{ path: string; text: string }> = [];
  const statuses: Array<{ path: string; status: string; err?: string }> = [];
  const saved: Array<{ path: string; out: string }> = [];
  let failNextPut = false;

  const deps: SaveQueueDeps = {
    fetchText: async (path) => {
      if (!disk.has(path)) throw new Error('not found');
      return disk.get(path)!;
    },
    putText: async (path, text) => {
      if (failNextPut) { failNextPut = false; throw new Error('boom'); }
      puts.push({ path, text });
      disk.set(path, text);
    },
    replaceBody: (base, body) => `${base}|${body}`,
    onStatus: (path, status, err) => { statuses.push({ path, status, err }); },
    onSaved: (path, out) => { saved.push({ path, out }); },
  };
  return { disk, puts, statuses, saved, deps, failPut: () => { failNextPut = true; } };
}

describe('createSaveQueue', () => {
  it('saves a queued edit and reports saving then saved', async () => {
    const h = harness({ p: 'BASE' });
    const q = createSaveQueue(h.deps);
    q.seedBase('p', 'BASE');
    q.request('p', 'hi');
    await tick();

    expect(h.puts).toEqual([{ path: 'p', text: 'BASE|hi' }]);
    expect(h.saved).toEqual([{ path: 'p', out: 'BASE|hi' }]);
    expect(h.statuses.map(s => s.status)).toEqual(['saving', 'saved']);
  });

  it('does not overwrite when the file changed underneath (conflict)', async () => {
    const h = harness({ p: 'CHANGED-BY-OTHER-WINDOW' });
    const q = createSaveQueue(h.deps);
    q.seedBase('p', 'BASE'); // we think the base is BASE, but disk differs
    q.request('p', 'hi');
    await tick();

    expect(h.puts).toEqual([]); // never wrote
    expect(h.statuses.map(s => s.status)).toContain('conflict');
  });

  it('saves edits made WHILE a save is in flight (navigate-away safety)', async () => {
    const h = harness({ p: 'BASE' });
    const q = createSaveQueue(h.deps);
    q.seedBase('p', 'BASE');
    q.request('p', 'a');   // begins draining (suspends on first await)
    q.request('p', 'b');   // queued while 'a' is in flight
    await tick();
    await tick();

    // Both written, in order, with the second based on the first's result —
    // the later edit is NOT dropped.
    expect(h.puts).toEqual([
      { path: 'p', text: 'BASE|a' },
      { path: 'p', text: 'BASE|a|b' },
    ]);
  });

  it('keeps the edit queued and retries after a failed PUT', async () => {
    const h = harness({ p: 'BASE' });
    const q = createSaveQueue(h.deps);
    q.seedBase('p', 'BASE');
    h.failPut();
    q.request('p', 'hi');
    await tick();
    expect(h.puts).toEqual([]);
    expect(h.statuses.map(s => s.status)).toContain('error');

    // A later flush retries the still-queued edit.
    q.request('p', 'hi');
    await tick();
    expect(h.puts).toEqual([{ path: 'p', text: 'BASE|hi' }]);
  });

  it('drop() discards a queued edit (used when reloading from disk)', async () => {
    const h = harness({ p: 'BASE' });
    const q = createSaveQueue(h.deps);
    q.seedBase('p', 'BASE');
    h.failPut();
    q.request('p', 'hi');     // errors, edit stays queued for retry
    await tick();
    expect(h.statuses.map(s => s.status)).toContain('error');
    q.drop('p');              // user chose to reload instead → discard
    await tick();
    expect(h.puts).toEqual([]); // never written
  });
});
