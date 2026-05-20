import { describe, it, expect } from 'vitest';
import type { Tab } from './types';
import {
  loadTabs, loadActiveIndex, saveTabs, saveActiveIndex,
  defaultTab, TABS_KEY, ACTIVE_KEY, LAST_SNAPSHOT_KEY, type Stores,
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
  it('returns a single default tab when both storages are empty', () => {
    const { s } = stores();
    expect(loadTabs(s)).toEqual([defaultTab()]);
  });

  it('reads the per-window session storage when present', () => {
    const tabs = [tabA, tabDoc];
    const { s } = stores({ [TABS_KEY]: JSON.stringify(tabs) });
    expect(loadTabs(s)).toEqual(tabs);
  });

  it('seeds from the localStorage :last snapshot when session is empty (reopen restore)', () => {
    const tabs = [tabDoc];
    const { s } = stores({}, { [LAST_SNAPSHOT_KEY]: JSON.stringify(tabs) });
    expect(loadTabs(s)).toEqual(tabs);
  });

  it('prefers session storage over the :last snapshot', () => {
    const sessionTabs = [tabA];
    const lastTabs = [tabDoc, tabThemes];
    const { s } = stores(
      { [TABS_KEY]: JSON.stringify(sessionTabs) },
      { [LAST_SNAPSHOT_KEY]: JSON.stringify(lastTabs) },
    );
    expect(loadTabs(s)).toEqual(sessionTabs);
  });

  it('accepts themes and activity tab kinds (regression: old loader dropped them)', () => {
    const tabs = [tabThemes, tabActivity];
    const { s } = stores({ [TABS_KEY]: JSON.stringify(tabs) });
    expect(loadTabs(s)).toEqual(tabs);
  });

  it('drops invalid tabs and falls back to default when nothing valid remains', () => {
    const garbage = JSON.stringify([{ nope: true }, 42, null]);
    const { s } = stores({ [TABS_KEY]: garbage });
    expect(loadTabs(s)).toEqual([defaultTab()]);
  });

  it('returns the default tab on corrupt JSON without throwing', () => {
    const { s } = stores({ [TABS_KEY]: '{not json' });
    expect(loadTabs(s)).toEqual([defaultTab()]);
  });
});

describe('loadActiveIndex', () => {
  it('defaults to 0 when unset', () => {
    const { s } = stores();
    expect(loadActiveIndex(3, s)).toBe(0);
  });

  it('reads a valid stored index', () => {
    const { s } = stores({ [ACTIVE_KEY]: '2' });
    expect(loadActiveIndex(3, s)).toBe(2);
  });

  it('clamps an out-of-range index to the last tab', () => {
    const { s } = stores({ [ACTIVE_KEY]: '9' });
    expect(loadActiveIndex(3, s)).toBe(2);
  });

  it('clamps a negative index to 0', () => {
    const { s } = stores({ [ACTIVE_KEY]: '-5' });
    expect(loadActiveIndex(3, s)).toBe(0);
  });

  it('returns 0 for a non-numeric value', () => {
    const { s } = stores({ [ACTIVE_KEY]: 'abc' });
    expect(loadActiveIndex(3, s)).toBe(0);
  });
});

describe('saveTabs', () => {
  it('writes both the per-window session copy and the localStorage :last snapshot', () => {
    const { session, local, s } = stores();
    const tabs = [tabA, tabDoc];
    saveTabs(tabs, s);
    expect(JSON.parse(session.getItem(TABS_KEY)!)).toEqual(tabs);
    expect(JSON.parse(local.getItem(LAST_SNAPSHOT_KEY)!)).toEqual(tabs);
  });
});

describe('saveActiveIndex', () => {
  it('writes the active index to session storage only', () => {
    const { session, local, s } = stores();
    saveActiveIndex(2, s);
    expect(session.getItem(ACTIVE_KEY)).toBe('2');
    expect(local.getItem(ACTIVE_KEY)).toBeNull();
  });
});
