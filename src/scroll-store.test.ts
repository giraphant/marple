import { describe, it, expect } from 'vitest';
import { loadScroll, saveScroll, SCROLL_KEY, SCROLL_CAP, type StorageLike } from './scroll-store';

/** Minimal Map-backed Storage so these tests need no DOM/runner globals. */
function fakeStorage(initial: Record<string, string> = {}): StorageLike & { _dump: () => Record<string, string> } {
  const m = new Map<string, string>(Object.entries(initial));
  return {
    getItem: (k: string) => (m.has(k) ? m.get(k)! : null),
    setItem: (k: string, v: string) => { m.set(k, v); },
    _dump: () => Object.fromEntries(m),
  };
}

describe('loadScroll', () => {
  it('returns 0 for an unknown path', () => {
    expect(loadScroll('vault/papers/x.md', fakeStorage())).toBe(0);
  });

  it('returns 0 when storage is empty / unset', () => {
    expect(loadScroll('vault/papers/x.md', fakeStorage())).toBe(0);
  });

  it('reads back a saved offset', () => {
    const s = fakeStorage();
    saveScroll('vault/papers/x.md', 1234, s);
    expect(loadScroll('vault/papers/x.md', s)).toBe(1234);
  });

  it('returns 0 on corrupt JSON without throwing', () => {
    expect(loadScroll('p', fakeStorage({ [SCROLL_KEY]: '{not json' }))).toBe(0);
  });

  it('ignores non-numeric / negative stored values', () => {
    const s = fakeStorage({ [SCROLL_KEY]: JSON.stringify({ a: 'x', b: -5, c: 10 }) });
    expect(loadScroll('a', s)).toBe(0);
    expect(loadScroll('b', s)).toBe(0);
    expect(loadScroll('c', s)).toBe(10);
  });
});

describe('saveScroll', () => {
  it('keeps each doc position independent (the QUA-68 bug)', () => {
    const s = fakeStorage();
    saveScroll('vault/papers/a.md', 3000, s);
    saveScroll('vault/papers/b.md', 600, s);
    // Switching back to a must NOT pick up b's offset.
    expect(loadScroll('vault/papers/a.md', s)).toBe(3000);
    expect(loadScroll('vault/papers/b.md', s)).toBe(600);
  });

  it('overwrites the same doc with the latest offset', () => {
    const s = fakeStorage();
    saveScroll('p', 100, s);
    saveScroll('p', 250, s);
    expect(loadScroll('p', s)).toBe(250);
  });

  it('clamps non-finite / negative offsets to 0 and rounds floats', () => {
    const s = fakeStorage();
    saveScroll('a', -10, s);
    saveScroll('b', Number.NaN, s);
    saveScroll('c', 12.7, s);
    expect(loadScroll('a', s)).toBe(0);
    expect(loadScroll('b', s)).toBe(0);
    expect(loadScroll('c', s)).toBe(13);
  });

  it('evicts the oldest entries past SCROLL_CAP', () => {
    const s = fakeStorage();
    for (let i = 0; i < SCROLL_CAP + 5; i++) saveScroll(`p${i}`, i + 1, s);
    // The first 5 inserted should have been evicted.
    expect(loadScroll('p0', s)).toBe(0);
    expect(loadScroll('p4', s)).toBe(0);
    // The most recent ones survive.
    expect(loadScroll(`p${SCROLL_CAP + 4}`, s)).toBe(SCROLL_CAP + 5);
    const map = JSON.parse(s._dump()[SCROLL_KEY]);
    expect(Object.keys(map).length).toBe(SCROLL_CAP);
  });

  it('re-saving a doc refreshes its LRU position so it is not evicted early', () => {
    const s = fakeStorage();
    saveScroll('keep', 42, s);
    for (let i = 0; i < SCROLL_CAP; i++) saveScroll(`p${i}`, i + 1, s);
    // 'keep' would be the oldest, but re-touch it before overflow pushes it out…
    saveScroll('keep', 99, s);
    saveScroll('overflow', 1, s); // forces one eviction
    expect(loadScroll('keep', s)).toBe(99); // survived because it was refreshed
    expect(loadScroll('p0', s)).toBe(0);    // p0 was the oldest, evicted
  });

  it('is a no-op for an empty path', () => {
    const s = fakeStorage();
    saveScroll('', 100, s);
    expect(s._dump()[SCROLL_KEY]).toBeUndefined();
  });
});
