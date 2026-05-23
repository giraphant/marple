import { describe, it, expect, beforeEach, vi } from 'vitest';
import { loadSettings, saveSettings, SETTINGS_KEY } from './settings';

/** Minimal Map-backed Storage so these tests need no DOM/runner globals
 *  (mirrors session.test.ts). loadSettings/saveSettings read the global each
 *  call, so stubbing it before the call is enough. */
function fakeStorage() {
  const m = new Map<string, string>();
  return {
    getItem: (k: string) => (m.has(k) ? m.get(k)! : null),
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
    clear: () => m.clear(),
    key: (i: number) => Array.from(m.keys())[i] ?? null,
    get length() { return m.size; },
  };
}

describe('settings external-editor defaults (QUA-72)', () => {
  beforeEach(() => vi.stubGlobal('localStorage', fakeStorage()));

  it('defaults to externalizing the editor on a fresh install', () => {
    const s = loadSettings();
    expect(s.useExternalEditor).toBe(true);
    expect(s.externalEditor).toBe('');
  });

  it('migrates an older saved blob (no editor fields) to the new defaults', () => {
    // A settings blob written before QUA-72 has no external-editor keys.
    localStorage.setItem(SETTINGS_KEY, JSON.stringify({ allowEditLLMBody: true, fontSize: 17 }));
    const s = loadSettings();
    expect(s.useExternalEditor).toBe(true);
    expect(s.externalEditor).toBe('');
    // Existing keys survive the merge.
    expect(s.allowEditLLMBody).toBe(true);
    expect(s.fontSize).toBe(17);
  });

  it('round-trips a chosen editor app and a disabled toggle', () => {
    const base = loadSettings();
    saveSettings({ ...base, useExternalEditor: false, externalEditor: 'Typora' });
    const s = loadSettings();
    expect(s.useExternalEditor).toBe(false);
    expect(s.externalEditor).toBe('Typora');
  });
});
