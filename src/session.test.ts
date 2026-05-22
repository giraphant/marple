import { describe, it, expect } from 'vitest';
import type { Tab } from './types';
import {
  loadTabs, loadActiveIndex, saveTabs, saveActiveIndex,
  defaultTab, TABS_KEY, ACTIVE_KEY, LEGACY_SNAPSHOT_KEY, type Stores,
} from './session';

/** Minimal Map-backed Storage so these tests need no DOM/runner globals. */
function fakeStorage(initial: Record<string, string> = {}) {
  const m = new Map<string, string>(Object.entries(initial));
  return {
    getItem: (k: string) => (m.has(k) ? m.get(k)! : null),
    setItem: (k: string, v: string) => { m.set(k, v); },
    _dump: () => Object.fromEntries(m),
  };
}

function stores(sessionInit: Record<string, string> = {}, localInit: Record<string, string> = {}) {
  const session = fakeStorage(sessionInit);
  const local = fakeStorage(localInit);
  return { session, local, s: { session, local } as Stores };
}

const tabA: Tab = { history: [{ kind: 'list', type: 'paper-analysis' }], cursor: 0 };
const tabDoc: Tab = { history: [{ kind: 'doc', path: 'vault/notes/x.md' }], cursor: 0 };
const tabThemes: Tab = { history: [{ kind: 'themes' }], cursor: 0 };
const tabActivity: Tab = { history: [{ kind: 'activity' }], cursor: 0 };

describe('loadTabs', () => {
  it('returns a single default tab when storage is empty', () => {
    const { s } = stores();
    expect(loadTabs(s)).toEqual([defaultTab()]);
  });

  it('reads the authoritative localStorage tabs when present', () => {
    const tabs = [tabA, tabDoc];
    const { s } = stores({}, { [TABS_KEY]: JSON.stringify(tabs) });
    expect(loadTabs(s)).toEqual(tabs);
  });

  it('migrates from the old per-window sessionStorage set when localStorage is empty', () => {
    const tabs = [tabDoc];
    const { s } = stores({ [TABS_KEY]: JSON.stringify(tabs) }, {});
    expect(loadTabs(s)).toEqual(tabs);
  });

  it('migrates from the legacy :last snapshot when nothing newer exists', () => {
    const tabs = [tabThemes, tabDoc];
    const { s } = stores({}, { [LEGACY_SNAPSHOT_KEY]: JSON.stringify(tabs) });
    expect(loadTabs(s)).toEqual(tabs);
  });

  it('prefers authoritative localStorage over both migration sources', () => {
    const authoritative = [tabA];
    const oldSession = [tabDoc, tabThemes];
    const legacy = [tabActivity];
    const { s } = stores(
      { [TABS_KEY]: JSON.stringify(oldSession) },
      { [TABS_KEY]: JSON.stringify(authoritative), [LEGACY_SNAPSHOT_KEY]: JSON.stringify(legacy) },
    );
    expect(loadTabs(s)).toEqual(authoritative);
  });

  it('accepts themes and activity tab kinds', () => {
    const tabs = [tabThemes, tabActivity];
    const { s } = stores({}, { [TABS_KEY]: JSON.stringify(tabs) });
    expect(loadTabs(s)).toEqual(tabs);
  });

  it('drops invalid tabs and falls back to default when nothing valid remains', () => {
    const garbage = JSON.stringify([{ nope: true }, 42, null]);
    const { s } = stores({}, { [TABS_KEY]: garbage });
    expect(loadTabs(s)).toEqual([defaultTab()]);
  });

  it('returns the default tab on corrupt JSON without throwing', () => {
    const { s } = stores({}, { [TABS_KEY]: '{not json' });
    expect(loadTabs(s)).toEqual([defaultTab()]);
  });
});

describe('loadActiveIndex', () => {
  it('defaults to 0 when unset', () => {
    const { s } = stores();
    expect(loadActiveIndex(3, s)).toBe(0);
  });

  it('reads a valid stored index from localStorage', () => {
    const { s } = stores({}, { [ACTIVE_KEY]: '2' });
    expect(loadActiveIndex(3, s)).toBe(2);
  });

  it('migrates an active index from the old sessionStorage value', () => {
    const { s } = stores({ [ACTIVE_KEY]: '1' }, {});
    expect(loadActiveIndex(3, s)).toBe(1);
  });

  it('clamps an out-of-range index to the last tab', () => {
    const { s } = stores({}, { [ACTIVE_KEY]: '9' });
    expect(loadActiveIndex(3, s)).toBe(2);
  });

  it('clamps a negative index to 0', () => {
    const { s } = stores({}, { [ACTIVE_KEY]: '-5' });
    expect(loadActiveIndex(3, s)).toBe(0);
  });

  it('returns 0 for a non-numeric value', () => {
    const { s } = stores({}, { [ACTIVE_KEY]: 'abc' });
    expect(loadActiveIndex(3, s)).toBe(0);
  });
});

describe('saveTabs / saveActiveIndex', () => {
  it('persists tabs to localStorage so they survive a launch', () => {
    const { session, local, s } = stores();
    const tabs = [tabA, tabDoc];
    saveTabs(tabs, s);
    expect(JSON.parse(local.getItem(TABS_KEY)!)).toEqual(tabs);
    // sessionStorage is no longer the live store.
    expect(session.getItem(TABS_KEY)).toBeNull();
  });

  it('persists the active index to localStorage', () => {
    const { session, local, s } = stores();
    saveActiveIndex(2, s);
    expect(local.getItem(ACTIVE_KEY)).toBe('2');
    expect(session.getItem(ACTIVE_KEY)).toBeNull();
  });
});

// The QUA-68 regression: a brand-new launch (sessionStorage gone, localStorage
// kept) must restore BOTH the tab set and the active tab — not reset to tab 0.
describe('launch persistence (QUA-68)', () => {
  it('restores the full set and the active index after a fresh launch', () => {
    const persisted = stores();
    const tabs = [tabA, tabDoc, tabThemes];
    saveTabs(tabs, persisted.s);
    saveActiveIndex(1, persisted.s);

    // Simulate relaunch: empty sessionStorage, same localStorage contents.
    const relaunched = stores({}, persisted.local._dump());
    const restored = loadTabs(relaunched.s);
    expect(restored).toEqual(tabs);
    expect(loadActiveIndex(restored.length, relaunched.s)).toBe(1);
  });
});
