import { describe, it, expect } from 'vitest';
import {
  loadDocPanelPrefs, clampPanelWidth, DOC_PANEL_KEY,
  DOC_PANEL_MIN_WIDTH, DOC_PANEL_MAX_WIDTH, DOC_PANEL_DEFAULT_WIDTH,
} from './doc-panel';

function fakeStorage(initial: Record<string, string> = {}) {
  const m = new Map(Object.entries(initial));
  return {
    getItem: (k: string) => (m.has(k) ? m.get(k)! : null),
    setItem: (k: string, v: string) => { m.set(k, v); },
  };
}

describe('clampPanelWidth', () => {
  it('clamps below/above range and rounds, falls back on non-finite', () => {
    expect(clampPanelWidth(10)).toBe(DOC_PANEL_MIN_WIDTH);
    expect(clampPanelWidth(9999)).toBe(DOC_PANEL_MAX_WIDTH);
    expect(clampPanelWidth(300.6)).toBe(301);
    expect(clampPanelWidth(NaN)).toBe(DOC_PANEL_DEFAULT_WIDTH);
  });
});

describe('loadDocPanelPrefs', () => {
  it('returns defaults when empty', () => {
    expect(loadDocPanelPrefs(fakeStorage())).toEqual({
      tab: 'info', collapsed: false, width: DOC_PANEL_DEFAULT_WIDTH,
    });
  });

  it('validates a stored blob and clamps width', () => {
    const s = fakeStorage({ [DOC_PANEL_KEY]: JSON.stringify({ tab: 'toc', collapsed: true, width: 9000 }) });
    expect(loadDocPanelPrefs(s)).toEqual({ tab: 'toc', collapsed: true, width: DOC_PANEL_MAX_WIDTH });
  });

  it('rejects an invalid tab and width, keeps valid fields', () => {
    const s = fakeStorage({ [DOC_PANEL_KEY]: JSON.stringify({ tab: 'bogus', width: 'x', collapsed: true }) });
    expect(loadDocPanelPrefs(s)).toEqual({ tab: 'info', collapsed: true, width: DOC_PANEL_DEFAULT_WIDTH });
  });

  it('survives malformed JSON', () => {
    const s = fakeStorage({ [DOC_PANEL_KEY]: '{not json' });
    expect(loadDocPanelPrefs(s).tab).toBe('info');
  });
});
